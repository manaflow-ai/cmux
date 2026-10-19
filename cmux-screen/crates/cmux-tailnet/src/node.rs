//! One tsnet node per process (the host binary, later the cmux daemon).

use std::ffi::{CStr, CString};
use std::os::fd::{FromRawFd, RawFd};
use std::os::raw::c_char;
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::sync::{Mutex, OnceLock};

use crate::localapi::LocalApi;
use crate::{Error, Result, Status, Watch, WhoIs, ffi};

/// How the node joins the tailnet. Set before [`Node::start`]; tsnet reads
/// these once.
#[derive(Debug, Clone)]
pub struct NodeConfig {
    /// Where the node keeps its keys and login (made 0700). One node per folder.
    pub state_dir: PathBuf,
    /// The device name on the tailnet, and the first label of its MagicDNS name.
    pub hostname: String,
    /// A one-time auth key for headless sign-in. None: sign in with the
    /// browser link from [`Node::watch`] or [`Status::auth_url`].
    pub auth_key: Option<String>,
    /// A coordination server other than Tailscale's (Headscale).
    pub control_url: Option<String>,
    /// Remove the device from the tailnet when it goes offline.
    pub ephemeral: bool,
    /// Where tsnet writes its log. None: discarded (tsnet logs are verbose
    /// and can carry the sign-in link; the link is read from the API instead).
    pub log_fd: Option<RawFd>,
}

impl NodeConfig {
    pub fn new(state_dir: impl Into<PathBuf>, hostname: impl Into<String>) -> Self {
        Self { state_dir: state_dir.into(), hostname: hostname.into(), auth_key: None, control_url: None, ephemeral: false, log_fd: None }
    }
}

pub struct Node {
    sd: ffi::Tailscale,
    local: OnceLock<std::result::Result<LocalApi, String>>,
    /// libtailscale keeps one unguarded "last error" per handle: every call
    /// that can set it runs with its errmsg read under this lock.
    calls: Mutex<()>,
}

// The handle is an integer into libtailscale's table; calls are serialized by `calls`.
unsafe impl Send for Node {}
unsafe impl Sync for Node {}

impl Node {
    pub fn new(config: &NodeConfig) -> Result<Self> {
        create_private_dir(&config.state_dir)?;
        let sd = unsafe { ffi::tailscale_new() };
        let node = Self { sd, local: OnceLock::new(), calls: Mutex::new(()) };
        let dir = cstring(config.state_dir.to_string_lossy().as_ref())?;
        node.call(|| unsafe { ffi::tailscale_set_dir(sd, dir.as_ptr()) })?;
        let hostname = cstring(&config.hostname)?;
        node.call(|| unsafe { ffi::tailscale_set_hostname(sd, hostname.as_ptr()) })?;
        if let Some(key) = &config.auth_key {
            let key = cstring(key.trim())?;
            node.call(|| unsafe { ffi::tailscale_set_authkey(sd, key.as_ptr()) })?;
        }
        if let Some(url) = &config.control_url {
            let url = cstring(url)?;
            node.call(|| unsafe { ffi::tailscale_set_control_url(sd, url.as_ptr()) })?;
        }
        node.call(|| unsafe { ffi::tailscale_set_ephemeral(sd, config.ephemeral as i32) })?;
        // Also routes tsnet's user log (which repeats the sign-in link) to
        // this fd or nowhere: patches/0001-user-logf-follows-logfd.patch.
        node.call(|| unsafe { ffi::tailscale_set_logfd(sd, config.log_fd.unwrap_or(-1)) })?;
        Ok(node)
    }

    /// Connects to the tailnet without waiting for sign-in. A node with no
    /// saved login and no auth key goes to NeedsLogin and offers a sign-in
    /// link ([`Node::watch`]).
    pub fn start(&self) -> Result<()> {
        self.call(|| unsafe { ffi::tailscale_start(self.sd) })
    }

    /// The node's current status (ipnstate.Status), read in memory.
    pub fn status(&self) -> Result<Status> {
        let mut json: *mut c_char = std::ptr::null_mut();
        self.call(|| unsafe { ffi::tailscale_status_json(self.sd, &mut json) })?;
        if json.is_null() {
            return Err(Error("status: no data".into()));
        }
        let text = unsafe { CStr::from_ptr(json) }.to_string_lossy().into_owned();
        unsafe { libc::free(json.cast()) };
        serde_json::from_str(&text).map_err(|error| Error(format!("status: {error}")))
    }

    /// State changes as they happen: sign-in link, Running, errors. Blocking
    /// iterator; run it on its own thread.
    pub fn watch(&self) -> Result<Watch> {
        self.local_api()?.watch()
    }

    /// Signs this node out of the tailnet (the device leaves the user's
    /// tailnet; a new sign-in link follows on [`Node::watch`] after
    /// [`Node::login_interactive`]).
    pub fn logout(&self) -> Result<()> {
        self.local_api()?.logout()
    }

    /// Asks for a new sign-in link, for a node in NeedsLogin that has none
    /// (after [`Node::logout`]). The link arrives on [`Node::watch`].
    pub fn login_interactive(&self) -> Result<()> {
        self.local_api()?.login_interactive()
    }

    /// Who is at a tailnet IP (or IP:port), from the node's control plane.
    /// Takes the bracketed IPv6 form libtailscale reports (`[fd7a::1]`) too.
    pub fn whois(&self, addr: &str) -> Result<WhoIs> {
        let addr = addr.strip_prefix('[').and_then(|ip| ip.strip_suffix(']')).unwrap_or(addr);
        self.local_api()?.whois(addr)
    }

    /// This node's tailnet addresses.
    pub fn ips(&self) -> Result<Vec<String>> {
        let mut buf = vec![0 as c_char; 256];
        self.call(|| unsafe { ffi::tailscale_getips(self.sd, buf.as_mut_ptr(), buf.len()) })?;
        let text = unsafe { CStr::from_ptr(buf.as_ptr()) }.to_string_lossy().into_owned();
        Ok(text.split(',').filter(|ip| !ip.is_empty()).map(str::to_owned).collect())
    }

    /// Listens for TCP on this node's tailnet addresses only (never on a
    /// LAN or public interface).
    pub fn listen_tcp(&self, port: u16) -> Result<Listener> {
        let network = cstring("tcp")?;
        let addr = cstring(&format!(":{port}"))?;
        let mut fd = -1;
        self.call(|| unsafe { ffi::tailscale_listen(self.sd, network.as_ptr(), addr.as_ptr(), &mut fd) })?;
        Ok(Listener { fd })
    }

    /// A TCP connection to `addr` (`host:port`, a MagicDNS name or tailnet IP) over the tailnet.
    /// Holds the call lock while it connects.
    pub fn dial_tcp(&self, addr: &str) -> Result<UnixStream> {
        let network = cstring("tcp")?;
        let addr = cstring(addr)?;
        let mut fd = -1;
        self.call(|| unsafe { ffi::tailscale_dial(self.sd, network.as_ptr(), addr.as_ptr(), &mut fd) })?;
        Ok(unsafe { UnixStream::from_raw_fd(fd) })
    }

    fn local_api(&self) -> Result<&LocalApi> {
        self.local
            .get_or_init(|| {
                let mut addr = vec![0 as c_char; 128];
                let mut proxy = vec![0 as c_char; 33];
                let mut local = vec![0 as c_char; 33];
                self.call(|| unsafe {
                    ffi::tailscale_loopback(self.sd, addr.as_mut_ptr(), addr.len(), proxy.as_mut_ptr(), local.as_mut_ptr())
                })
                .map_err(|error| error.0)?;
                let addr = unsafe { CStr::from_ptr(addr.as_ptr()) }.to_string_lossy().into_owned();
                let local = unsafe { CStr::from_ptr(local.as_ptr()) }.to_string_lossy().into_owned();
                Ok(LocalApi::new(&addr, &local))
            })
            .as_ref()
            .map_err(|message| Error(message.clone()))
    }

    /// Runs one libtailscale call and reads its error under the call lock.
    fn call(&self, f: impl FnOnce() -> i32) -> Result<()> {
        let _serialized = self.calls.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        let code = f();
        match code {
            0 => Ok(()),
            libc::EBADF => Err(Error("libtailscale: bad handle".into())),
            libc::ERANGE => Err(Error("libtailscale: buffer too small".into())),
            _ => Err(Error(self.message())),
        }
    }

    fn message(&self) -> String {
        let mut buf = vec![0 as c_char; 1024];
        if unsafe { ffi::tailscale_errmsg(self.sd, buf.as_mut_ptr(), buf.len()) } != 0 {
            return "libtailscale: unknown error".into();
        }
        unsafe { CStr::from_ptr(buf.as_ptr()) }.to_string_lossy().into_owned()
    }
}

impl Drop for Node {
    fn drop(&mut self) {
        unsafe { ffi::tailscale_close(self.sd) };
    }
}

/// A TCP listener on the tailnet. Each accepted connection carries the
/// peer's tailnet IP, which is what [`Node::whois`] takes.
pub struct Listener {
    fd: ffi::TailscaleListener,
}

impl Listener {
    /// Blocks until a peer connects.
    pub fn accept(&self) -> Result<(UnixStream, String)> {
        let mut conn = -1;
        match unsafe { ffi::tailscale_accept(self.fd, &mut conn) } {
            0 => {}
            libc::EBADF => return Err(Error("listener closed".into())),
            _ => return Err(Error("accept failed".into())),
        }
        let stream = unsafe { UnixStream::from_raw_fd(conn) };
        let mut buf = vec![0 as c_char; 64];
        if unsafe { ffi::tailscale_getremoteaddr(self.fd, conn, buf.as_mut_ptr(), buf.len()) } != 0 {
            // No address means no identity: refuse the connection.
            return Err(Error("accept: no remote address".into()));
        }
        let remote = unsafe { CStr::from_ptr(buf.as_ptr()) }.to_string_lossy().into_owned();
        Ok((stream, remote))
    }
}

impl Drop for Listener {
    fn drop(&mut self) {
        unsafe { libc::close(self.fd) };
    }
}

fn cstring(value: &str) -> Result<CString> {
    CString::new(value).map_err(|_| Error(format!("NUL byte in {value:?}")))
}

fn create_private_dir(path: &std::path::Path) -> Result<()> {
    use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(path)
        .and_then(|()| std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700)))
        .map_err(|error| Error(format!("state dir {}: {error}", path.display())))
}
