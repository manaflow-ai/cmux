use crate::{CmuxError, Result};
use serde_json::Value;
use std::io::{BufRead, BufReader, Write};
use std::net::Shutdown;
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::time::Duration;

pub(crate) struct JsonLineConnection {
    writer: UnixStream,
    reader: BufReader<UnixStream>,
    max_frame_bytes: usize,
}

impl JsonLineConnection {
    pub(crate) fn connect(
        socket_path: &Path,
        timeout: Duration,
        max_frame_bytes: usize,
    ) -> Result<Self> {
        let stream = UnixStream::connect(socket_path).map_err(|error| {
            CmuxError::Connection(format!(
                "cannot connect to session socket {}: {error}",
                socket_path.display()
            ))
        })?;
        Self::from_stream(stream, timeout, max_frame_bytes)
    }

    pub(crate) fn from_stream(
        stream: UnixStream,
        timeout: Duration,
        max_frame_bytes: usize,
    ) -> Result<Self> {
        if max_frame_bytes == 0 {
            return Err(CmuxError::InvalidArgument(
                "max_frame_bytes must be greater than zero".to_string(),
            ));
        }
        stream
            .set_read_timeout(Some(timeout))
            .map_err(|error| CmuxError::Connection(format!("set read timeout failed: {error}")))?;
        stream
            .set_write_timeout(Some(timeout))
            .map_err(|error| CmuxError::Connection(format!("set write timeout failed: {error}")))?;
        let writer = stream
            .try_clone()
            .map_err(|error| CmuxError::Connection(format!("socket clone failed: {error}")))?;
        Ok(Self { writer, reader: BufReader::new(stream), max_frame_bytes })
    }

    pub(crate) fn shutdown_clone(&self) -> Result<UnixStream> {
        self.writer
            .try_clone()
            .map_err(|error| CmuxError::Connection(format!("socket clone failed: {error}")))
    }

    pub(crate) fn send(&mut self, value: &Value) -> Result<()> {
        let encoded =
            serde_json::to_vec(value).map_err(|error| CmuxError::Decode(error.to_string()))?;
        if encoded.len() > self.max_frame_bytes {
            return Err(CmuxError::FrameTooLarge {
                size: encoded.len(),
                limit: self.max_frame_bytes,
            });
        }
        self.writer
            .write_all(&encoded)
            .and_then(|()| self.writer.write_all(b"\n"))
            .map_err(|error| CmuxError::Connection(format!("socket write failed: {error}")))
    }

    pub(crate) fn recv(&mut self) -> Result<Value> {
        let frame = self.read_frame()?;
        serde_json::from_slice(&frame).map_err(|error| CmuxError::Decode(error.to_string()))
    }

    pub(crate) fn with_read_timeout<T>(
        &mut self,
        timeout: Duration,
        operation: impl FnOnce(&mut Self) -> Result<T>,
    ) -> Result<T> {
        let previous = self.reader.get_ref().read_timeout().map_err(|error| {
            CmuxError::Connection(format!("read timeout lookup failed: {error}"))
        })?;
        self.reader
            .get_ref()
            .set_read_timeout(Some(timeout))
            .map_err(|error| CmuxError::Connection(format!("set read timeout failed: {error}")))?;
        let result = operation(self);
        let restore = self.reader.get_ref().set_read_timeout(previous).map_err(|error| {
            CmuxError::Connection(format!("restore read timeout failed: {error}"))
        });
        match (result, restore) {
            (Ok(value), Ok(())) => Ok(value),
            (Err(error), _) | (Ok(_), Err(error)) => Err(error),
        }
    }

    pub(crate) fn close(&self) {
        let _ = self.writer.shutdown(Shutdown::Both);
    }

    fn read_frame(&mut self) -> Result<Vec<u8>> {
        let mut frame = Vec::with_capacity(self.max_frame_bytes.min(8 * 1024));
        loop {
            let available = match self.reader.fill_buf() {
                Ok([]) => {
                    return Err(CmuxError::Connection("session socket closed".to_string()));
                }
                Ok(bytes) => bytes,
                Err(error)
                    if matches!(
                        error.kind(),
                        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                    ) =>
                {
                    return Err(CmuxError::Timeout("session did not respond".to_string()));
                }
                Err(error) => {
                    return Err(CmuxError::Connection(format!("socket read failed: {error}")));
                }
            };
            let newline = available.iter().position(|byte| *byte == b'\n');
            let chunk_len = newline.unwrap_or(available.len());
            if frame.len().saturating_add(chunk_len) > self.max_frame_bytes {
                self.close();
                return Err(CmuxError::FrameTooLarge {
                    size: frame.len().saturating_add(chunk_len),
                    limit: self.max_frame_bytes,
                });
            }
            frame.extend_from_slice(&available[..chunk_len]);
            self.reader.consume(chunk_len + usize::from(newline.is_some()));
            if newline.is_some() {
                if frame.last() == Some(&b'\r') {
                    frame.pop();
                }
                return Ok(frame);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn pair(limit: usize) -> (JsonLineConnection, UnixStream) {
        let (client, server) = UnixStream::pair().unwrap();
        (JsonLineConnection::from_stream(client, Duration::from_secs(1), limit).unwrap(), server)
    }

    #[test]
    fn receives_crlf_json_frames() {
        let (mut client, mut server) = pair(64);
        server.write_all(b"{\"ok\":true}\r\n").unwrap();
        assert_eq!(client.recv().unwrap(), serde_json::json!({"ok": true}));
    }

    #[test]
    fn rejects_oversized_inbound_frame_without_unbounded_allocation() {
        let (mut client, mut server) = pair(8);
        server.write_all(b"{\"long\":\"0123456789\"}\n").unwrap();
        assert!(matches!(client.recv(), Err(CmuxError::FrameTooLarge { limit: 8, .. })));
    }

    #[test]
    fn rejects_oversized_outbound_frame() {
        let (mut client, _server) = pair(8);
        assert!(matches!(
            client.send(&serde_json::json!({"long": "0123456789"})),
            Err(CmuxError::FrameTooLarge { limit: 8, .. })
        ));
    }
}
