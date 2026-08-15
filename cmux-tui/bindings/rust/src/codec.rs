use crate::Result;
use crate::client::CmuxError;
use serde_json::Value;
use std::io::{BufRead, BufReader, Write};
use std::mem::{offset_of, size_of, zeroed};
use std::net::Shutdown;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::time::{Duration, Instant};

#[cfg(test)]
thread_local! {
    static FORCE_PENDING_CONNECT: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
    static FORCED_CONNECT_ATTEMPTS: std::cell::Cell<usize> = const { std::cell::Cell::new(0) };
    static FORCED_CONNECT_POLLS: std::cell::Cell<usize> = const { std::cell::Cell::new(0) };
    static FORCED_CONNECT_POLL_LIMIT: std::cell::Cell<usize> = const { std::cell::Cell::new(0) };
    static FORCED_CONNECT_AFTER_FIRST_POLL: std::cell::RefCell<Option<Box<dyn FnOnce()>>> =
        const { std::cell::RefCell::new(None) };
}

#[cfg(test)]
pub(crate) struct ForcedPendingConnectProbe;

#[cfg(test)]
impl ForcedPendingConnectProbe {
    pub(crate) fn install() -> Self {
        FORCE_PENDING_CONNECT.with(|forced| {
            assert!(!forced.replace(true), "a pending-connect probe is already installed");
        });
        FORCED_CONNECT_ATTEMPTS.with(|attempts| attempts.set(0));
        FORCED_CONNECT_POLLS.with(|polls| polls.set(0));
        FORCED_CONNECT_POLL_LIMIT.with(|limit| limit.set(0));
        FORCED_CONNECT_AFTER_FIRST_POLL.with(|action| drop(action.borrow_mut().take()));
        Self
    }

    pub(crate) fn install_with_poll_limit(limit: usize) -> Self {
        assert!(limit > 0, "a pending-connect poll limit must be positive");
        let probe = Self::install();
        FORCED_CONNECT_POLL_LIMIT.with(|configured| configured.set(limit));
        probe
    }

    pub(crate) fn install_with_after_first_poll(action: impl FnOnce() + 'static) -> Self {
        let probe = Self::install();
        FORCED_CONNECT_AFTER_FIRST_POLL.with(|configured| {
            *configured.borrow_mut() = Some(Box::new(action));
        });
        probe
    }

    pub(crate) fn attempts(&self) -> usize {
        FORCED_CONNECT_ATTEMPTS.with(std::cell::Cell::get)
    }

    pub(crate) fn polls(&self) -> usize {
        FORCED_CONNECT_POLLS.with(std::cell::Cell::get)
    }
}

#[cfg(test)]
impl Drop for ForcedPendingConnectProbe {
    fn drop(&mut self) {
        FORCE_PENDING_CONNECT.with(|forced| forced.set(false));
        FORCED_CONNECT_ATTEMPTS.with(|attempts| attempts.set(0));
        FORCED_CONNECT_POLLS.with(|polls| polls.set(0));
        FORCED_CONNECT_POLL_LIMIT.with(|limit| limit.set(0));
        FORCED_CONNECT_AFTER_FIRST_POLL.with(|action| drop(action.borrow_mut().take()));
    }
}

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
        connect_timeout: Duration,
        io_timeout: Duration,
        max_frame_bytes: usize,
    ) -> Result<Self> {
        let stream = connect_unix_with_timeout(socket_path, connect_timeout)?;
        Self::from_stream(stream, io_timeout, max_frame_bytes)
    }

    pub(crate) fn connect_with_poll_checks(
        socket_path: &Path,
        connect_timeout: Duration,
        io_timeout: Duration,
        max_frame_bytes: usize,
        poll_interval: Duration,
        check: impl FnMut() -> Result<()>,
    ) -> Result<Self> {
        let stream =
            connect_unix_with_poll_checks(socket_path, connect_timeout, poll_interval, check)?;
        Self::from_stream(stream, io_timeout, max_frame_bytes)
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
        if let Err(error) = self.reader.get_ref().set_read_timeout(None) {
            if error.kind() == std::io::ErrorKind::InvalidInput {
                // macOS can reject SO_RCVTIMEO changes after the peer queues
                // its final frame and closes. The existing timeout still lets
                // us drain that frame or observe EOF without blocking forever.
                return operation(self);
            }
            return Err(CmuxError::Connection(format!("clear read timeout failed: {error}")));
        }
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

fn connect_unix_with_timeout(socket_path: &Path, timeout: Duration) -> Result<UnixStream> {
    connect_unix_with_poll_checks(socket_path, timeout, timeout, || Ok(()))
}

fn connect_unix_with_poll_checks(
    socket_path: &Path,
    timeout: Duration,
    poll_interval: Duration,
    mut check: impl FnMut() -> Result<()>,
) -> Result<UnixStream> {
    if timeout.is_zero() {
        return Err(connect_timeout_error(socket_path));
    }
    if poll_interval.is_zero() {
        return Err(CmuxError::InvalidArgument(
            "session socket connect poll interval must be greater than zero".to_string(),
        ));
    }
    #[cfg(test)]
    if FORCE_PENDING_CONNECT.with(std::cell::Cell::get) {
        FORCED_CONNECT_ATTEMPTS.with(|attempts| attempts.set(attempts.get() + 1));
        let deadline = Instant::now().checked_add(timeout).ok_or_else(|| {
            CmuxError::InvalidArgument("session socket connect timeout is too large".to_string())
        })?;
        loop {
            if FORCED_CONNECT_POLLS.with(std::cell::Cell::get) > 0 {
                FORCED_CONNECT_AFTER_FIRST_POLL.with(|action| {
                    if let Some(action) = action.borrow_mut().take() {
                        action();
                    }
                });
            }
            check()?;
            let now = Instant::now();
            if now >= deadline {
                return Err(connect_timeout_error(socket_path));
            }
            let reached_poll_limit = FORCED_CONNECT_POLLS.with(|polls| {
                let count = polls.get().saturating_add(1);
                polls.set(count);
                FORCED_CONNECT_POLL_LIMIT.with(|limit| {
                    let limit = limit.get();
                    limit > 0 && count >= limit
                })
            });
            if reached_poll_limit {
                return Err(connect_timeout_error(socket_path));
            }
            std::thread::sleep(deadline.saturating_duration_since(now).min(poll_interval));
        }
    }
    let path = socket_path.as_os_str().as_bytes();
    if path.contains(&0) {
        return Err(CmuxError::InvalidArgument(
            "session socket path contains a NUL byte".to_string(),
        ));
    }
    let mut address: libc::sockaddr_un = unsafe { zeroed() };
    if path.len() >= address.sun_path.len() {
        return Err(CmuxError::InvalidArgument(format!(
            "session socket path is too long: {}",
            socket_path.display()
        )));
    }
    address.sun_family = libc::AF_UNIX as libc::sa_family_t;
    for (destination, source) in address.sun_path.iter_mut().zip(path) {
        *destination = *source as libc::c_char;
    }
    let address_length =
        offset_of!(libc::sockaddr_un, sun_path).saturating_add(path.len()).saturating_add(1);
    #[cfg(any(
        target_vendor = "apple",
        target_os = "freebsd",
        target_os = "netbsd",
        target_os = "openbsd",
        target_os = "dragonfly",
    ))]
    {
        address.sun_len = address_length.try_into().map_err(|_| {
            CmuxError::InvalidArgument("session socket address is too long".to_string())
        })?;
    }

    let creation = platform_socket_creation_plan();
    let raw_descriptor = unsafe { libc::socket(libc::AF_UNIX, creation.socket_type, 0) };
    if raw_descriptor < 0 {
        return Err(connect_error(socket_path, std::io::Error::last_os_error()));
    }
    let descriptor = unsafe { OwnedFd::from_raw_fd(raw_descriptor) };
    if creation.needs_cloexec_fcntl {
        let descriptor_flags = unsafe { libc::fcntl(descriptor.as_raw_fd(), libc::F_GETFD) };
        if descriptor_flags < 0
            || unsafe {
                libc::fcntl(
                    descriptor.as_raw_fd(),
                    libc::F_SETFD,
                    descriptor_flags | libc::FD_CLOEXEC,
                )
            } < 0
        {
            return Err(connect_error(socket_path, std::io::Error::last_os_error()));
        }
    }
    #[cfg(any(
        target_vendor = "apple",
        target_os = "dragonfly",
        target_os = "freebsd",
        target_os = "netbsd",
    ))]
    set_no_sigpipe(descriptor.as_raw_fd()).map_err(|error| connect_error(socket_path, error))?;
    let status_flags = unsafe { libc::fcntl(descriptor.as_raw_fd(), libc::F_GETFL) };
    if status_flags < 0
        || unsafe {
            libc::fcntl(descriptor.as_raw_fd(), libc::F_SETFL, status_flags | libc::O_NONBLOCK)
        } < 0
    {
        return Err(connect_error(socket_path, std::io::Error::last_os_error()));
    }

    let connected = unsafe {
        libc::connect(
            descriptor.as_raw_fd(),
            (&raw const address).cast::<libc::sockaddr>(),
            address_length as libc::socklen_t,
        )
    };
    if connected < 0 {
        let error = std::io::Error::last_os_error();
        if !matches!(
            error.raw_os_error(),
            Some(libc::EINPROGRESS | libc::EWOULDBLOCK | libc::EALREADY)
        ) {
            return Err(connect_error(socket_path, error));
        }
        wait_for_connect_with_poll_checks(
            descriptor.as_raw_fd(),
            timeout,
            socket_path,
            poll_interval,
            &mut check,
        )?;
    }

    if unsafe {
        libc::fcntl(descriptor.as_raw_fd(), libc::F_SETFL, status_flags & !libc::O_NONBLOCK)
    } < 0
    {
        return Err(connect_error(socket_path, std::io::Error::last_os_error()));
    }
    Ok(UnixStream::from(descriptor))
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct SocketCreationPlan {
    socket_type: libc::c_int,
    needs_cloexec_fcntl: bool,
}

fn socket_creation_plan(atomic_cloexec_flag: Option<libc::c_int>) -> SocketCreationPlan {
    match atomic_cloexec_flag {
        Some(flag) => {
            SocketCreationPlan { socket_type: libc::SOCK_STREAM | flag, needs_cloexec_fcntl: false }
        }
        None => SocketCreationPlan { socket_type: libc::SOCK_STREAM, needs_cloexec_fcntl: true },
    }
}

#[cfg(any(
    target_os = "android",
    target_os = "cygwin",
    target_os = "dragonfly",
    target_os = "freebsd",
    target_os = "hurd",
    target_os = "illumos",
    target_os = "linux",
    target_os = "netbsd",
    target_os = "nto",
    target_os = "openbsd",
    target_os = "solaris",
))]
const PLATFORM_ATOMIC_CLOEXEC_FLAG: Option<libc::c_int> = Some(libc::SOCK_CLOEXEC);

#[cfg(not(any(
    target_os = "android",
    target_os = "cygwin",
    target_os = "dragonfly",
    target_os = "freebsd",
    target_os = "hurd",
    target_os = "illumos",
    target_os = "linux",
    target_os = "netbsd",
    target_os = "nto",
    target_os = "openbsd",
    target_os = "solaris",
)))]
const PLATFORM_ATOMIC_CLOEXEC_FLAG: Option<libc::c_int> = None;

fn platform_socket_creation_plan() -> SocketCreationPlan {
    socket_creation_plan(PLATFORM_ATOMIC_CLOEXEC_FLAG)
}

#[cfg(any(
    target_vendor = "apple",
    target_os = "dragonfly",
    target_os = "freebsd",
    target_os = "netbsd",
))]
fn set_no_sigpipe(descriptor: libc::c_int) -> std::io::Result<()> {
    let enabled: libc::c_int = 1;
    if unsafe {
        libc::setsockopt(
            descriptor,
            libc::SOL_SOCKET,
            libc::SO_NOSIGPIPE,
            (&raw const enabled).cast(),
            size_of::<libc::c_int>() as libc::socklen_t,
        )
    } < 0
    {
        return Err(std::io::Error::last_os_error());
    }
    Ok(())
}

#[cfg(test)]
fn wait_for_connect(descriptor: libc::c_int, timeout: Duration, socket_path: &Path) -> Result<()> {
    wait_for_connect_with_poll_checks(descriptor, timeout, socket_path, timeout, &mut || Ok(()))
}

fn wait_for_connect_with_poll_checks(
    descriptor: libc::c_int,
    timeout: Duration,
    socket_path: &Path,
    poll_interval: Duration,
    check: &mut impl FnMut() -> Result<()>,
) -> Result<()> {
    let deadline = Instant::now().checked_add(timeout).ok_or_else(|| {
        CmuxError::InvalidArgument("session socket connect timeout is too large".to_string())
    })?;
    loop {
        check()?;
        let now = Instant::now();
        if now >= deadline {
            return Err(connect_timeout_error(socket_path));
        }
        let remaining = deadline.saturating_duration_since(now).min(poll_interval);
        let timeout_ms = remaining
            .as_nanos()
            .saturating_add(999_999)
            .checked_div(1_000_000)
            .unwrap_or(u128::MAX)
            .clamp(1, libc::c_int::MAX as u128) as libc::c_int;
        let mut poll_descriptor =
            libc::pollfd { fd: descriptor, events: libc::POLLOUT, revents: 0 };
        let ready = unsafe { libc::poll(&raw mut poll_descriptor, 1, timeout_ms) };
        if ready == 0 {
            continue;
        }
        if ready < 0 {
            let error = std::io::Error::last_os_error();
            if error.kind() == std::io::ErrorKind::Interrupted {
                continue;
            }
            return Err(connect_error(socket_path, error));
        }
        if poll_descriptor.revents & libc::POLLNVAL != 0 {
            return Err(connect_error(
                socket_path,
                std::io::Error::new(
                    std::io::ErrorKind::NotConnected,
                    "session socket descriptor became invalid",
                ),
            ));
        }
        let mut socket_error = 0;
        let mut socket_error_length = size_of::<libc::c_int>() as libc::socklen_t;
        if unsafe {
            libc::getsockopt(
                descriptor,
                libc::SOL_SOCKET,
                libc::SO_ERROR,
                (&raw mut socket_error).cast(),
                &raw mut socket_error_length,
            )
        } < 0
        {
            return Err(connect_error(socket_path, std::io::Error::last_os_error()));
        }
        if socket_error != 0 {
            return Err(connect_error(
                socket_path,
                std::io::Error::from_raw_os_error(socket_error),
            ));
        }
        return Ok(());
    }
}

fn connect_error(socket_path: &Path, error: std::io::Error) -> CmuxError {
    CmuxError::Connection(format!(
        "cannot connect to session socket {}: {error}",
        socket_path.display()
    ))
}

fn connect_timeout_error(socket_path: &Path) -> CmuxError {
    CmuxError::Timeout(format!(
        "cannot connect to session socket {} before the deadline",
        socket_path.display()
    ))
}

fn socket_timeout(timeout: Duration) -> Duration {
    timeout.max(Duration::from_micros(1))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use std::os::unix::net::UnixListener;
    use std::sync::atomic::{AtomicU64, Ordering};

    static NEXT_SOCKET_ID: AtomicU64 = AtomicU64::new(1);

    struct SocketPath(std::path::PathBuf);

    impl Drop for SocketPath {
        fn drop(&mut self) {
            let _ = std::fs::remove_file(&self.0);
        }
    }

    fn listening_socket(name: &str) -> (SocketPath, UnixListener) {
        let id = NEXT_SOCKET_ID.fetch_add(1, Ordering::Relaxed);
        let path = SocketPath(
            std::env::temp_dir()
                .join(format!("cmux-rust-codec-{name}-{}-{id}.sock", std::process::id())),
        );
        let listener = UnixListener::bind(&path.0).unwrap();
        (path, listener)
    }

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

    #[test]
    fn connect_poll_stops_at_its_deadline() {
        let (mut writer, _reader) = UnixStream::pair().unwrap();
        writer.set_nonblocking(true).unwrap();
        let block = [0_u8; 16 * 1024];
        loop {
            match writer.write(&block) {
                Ok(_) => continue,
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => break,
                Err(error) => panic!("failed to fill socket send buffer: {error}"),
            }
        }
        let started = Instant::now();
        assert!(matches!(
            wait_for_connect(
                writer.as_raw_fd(),
                Duration::from_millis(10),
                Path::new("deadline-test.sock"),
            ),
            Err(CmuxError::Timeout(_))
        ));
        assert!(started.elapsed() < Duration::from_secs(1));
    }

    #[test]
    fn socket_creation_plan_uses_atomic_close_on_exec_when_available() {
        let atomic_flag = 0x4000;
        assert_eq!(
            socket_creation_plan(Some(atomic_flag)),
            SocketCreationPlan {
                socket_type: libc::SOCK_STREAM | atomic_flag,
                needs_cloexec_fcntl: false,
            }
        );
        assert_eq!(
            socket_creation_plan(None),
            SocketCreationPlan { socket_type: libc::SOCK_STREAM, needs_cloexec_fcntl: true }
        );
    }

    #[cfg(any(
        target_vendor = "apple",
        target_os = "dragonfly",
        target_os = "freebsd",
        target_os = "netbsd",
    ))]
    #[test]
    fn connector_disables_sigpipe_on_supported_sockets() {
        let (path, listener) = listening_socket("nosigpipe");
        let stream = connect_unix_with_timeout(&path.0, Duration::from_secs(1)).unwrap();
        let (_peer, _) = listener.accept().unwrap();
        let mut enabled: libc::c_int = 0;
        let mut length = size_of::<libc::c_int>() as libc::socklen_t;
        assert_eq!(
            unsafe {
                libc::getsockopt(
                    stream.as_raw_fd(),
                    libc::SOL_SOCKET,
                    libc::SO_NOSIGPIPE,
                    (&raw mut enabled).cast(),
                    &raw mut length,
                )
            },
            0
        );
        assert_eq!(length as usize, size_of::<libc::c_int>());
        assert_eq!(enabled, 1);
    }

    #[cfg(any(
        target_vendor = "apple",
        target_os = "dragonfly",
        target_os = "freebsd",
        target_os = "netbsd",
    ))]
    #[test]
    fn sigpipe_setup_reports_invalid_descriptors() {
        let error = set_no_sigpipe(-1).unwrap_err();
        assert_eq!(error.raw_os_error(), Some(libc::EBADF));
    }

    #[test]
    fn connector_restores_blocking_mode_and_sets_close_on_exec() {
        let (path, listener) = listening_socket("descriptor-flags");
        let stream = connect_unix_with_timeout(&path.0, Duration::from_secs(1)).unwrap();
        let (_peer, _) = listener.accept().unwrap();
        let descriptor_flags = unsafe { libc::fcntl(stream.as_raw_fd(), libc::F_GETFD) };
        assert!(descriptor_flags >= 0);
        assert_ne!(descriptor_flags & libc::FD_CLOEXEC, 0);
        let status_flags = unsafe { libc::fcntl(stream.as_raw_fd(), libc::F_GETFL) };
        assert!(status_flags >= 0);
        assert_eq!(status_flags & libc::O_NONBLOCK, 0);
    }
}
