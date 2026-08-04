use crate::Result;
use crate::client::CmuxError;
use serde_json::Value;
use std::io::{BufRead, BufReader, Write};
use std::net::Shutdown;
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::time::Duration;

pub(crate) struct JsonLineConnection {
    writer: UnixStream,
    reader: BufReader<UnixStream>,
    partial_frame: Vec<u8>,
    read_timeout: Duration,
    write_timeout: Duration,
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
        Ok(Self {
            writer,
            reader: BufReader::new(stream),
            partial_frame: Vec::new(),
            read_timeout: timeout,
            write_timeout: timeout,
            max_frame_bytes,
        })
    }

    pub(crate) fn shutdown_clone(&self) -> Result<UnixStream> {
        self.writer
            .try_clone()
            .map_err(|error| CmuxError::Connection(format!("socket clone failed: {error}")))
    }

    pub(crate) fn send(&mut self, value: &Value) -> Result<()> {
        self.send_with_limit(value, self.max_frame_bytes)
    }

    pub(crate) fn send_with_limit(&mut self, value: &Value, limit: usize) -> Result<()> {
        let encoded =
            serde_json::to_vec(value).map_err(|error| CmuxError::Decode(error.to_string()))?;
        if encoded.len() > limit {
            return Err(CmuxError::FrameTooLarge { size: encoded.len(), limit });
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
        let timeout = socket_timeout(timeout);
        let previous = self.read_timeout;
        if let Err(error) = self.reader.get_ref().set_read_timeout(Some(timeout)) {
            if error.kind() == std::io::ErrorKind::InvalidInput {
                // macOS may reject SO_RCVTIMEO after the peer has queued its
                // final bytes and closed. Draining the buffered frame or EOF
                // is nonblocking in that state, and the previous timeout
                // remains installed if the socket is unexpectedly still live.
                return operation(self);
            }
            return Err(CmuxError::Connection(format!("set read timeout failed: {error}")));
        }
        self.read_timeout = timeout;
        let result = operation(self);
        if self.reader.get_ref().set_read_timeout(Some(previous)).is_ok() {
            self.read_timeout = previous;
        }
        result
    }

    pub(crate) fn without_read_timeout<T>(
        &mut self,
        operation: impl FnOnce(&mut Self) -> Result<T>,
    ) -> Result<T> {
        let previous = self.read_timeout;
        self.reader.get_ref().set_read_timeout(None).map_err(|error| {
            CmuxError::Connection(format!("clear read timeout failed: {error}"))
        })?;
        let result = operation(self);
        if self.reader.get_ref().set_read_timeout(Some(previous)).is_ok() {
            self.read_timeout = previous;
        }
        result
    }

    pub(crate) fn with_write_timeout<T>(
        &mut self,
        timeout: Duration,
        operation: impl FnOnce(&mut Self) -> Result<T>,
    ) -> Result<T> {
        let timeout = socket_timeout(timeout);
        let previous = self.write_timeout;
        self.writer
            .set_write_timeout(Some(timeout))
            .map_err(|error| CmuxError::Connection(format!("set write timeout failed: {error}")))?;
        self.write_timeout = timeout;
        let result = operation(self);
        if self.writer.set_write_timeout(Some(previous)).is_ok() {
            self.write_timeout = previous;
        }
        result
    }

    pub(crate) fn close(&self) {
        let _ = self.writer.shutdown(Shutdown::Both);
    }

    fn read_frame(&mut self) -> Result<Vec<u8>> {
        let mut frame = std::mem::take(&mut self.partial_frame);
        if frame.capacity() == 0 {
            frame.reserve(self.max_frame_bytes.min(8 * 1024));
        }
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
                    self.partial_frame = frame;
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

fn socket_timeout(timeout: Duration) -> Duration {
    timeout.max(Duration::from_micros(1))
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
