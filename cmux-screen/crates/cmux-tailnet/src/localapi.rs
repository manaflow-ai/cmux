//! The node's LocalAPI, served by tsnet on a loopback port that only this
//! process knows the password for (`tailscale_loopback`).

use std::io::{BufRead, BufReader, Read};

use base64::Engine;

use crate::{Error, Notify, Result, WhoIs};

/// ipn.NotifyInitialState: the first message carries the current state and sign-in URL.
const NOTIFY_INITIAL_STATE: u64 = 1 << 1;
/// ipn.NotifyNoPrivateKeys.
const NOTIFY_NO_PRIVATE_KEYS: u64 = 1 << 4;

pub(crate) struct LocalApi {
    base: String,
    authorization: String,
    agent: ureq::Agent,
}

impl LocalApi {
    pub(crate) fn new(addr: &str, cred: &str) -> Self {
        let token = base64::engine::general_purpose::STANDARD.encode(format!(":{cred}"));
        // Requests stay on loopback: never through a proxy from the
        // environment (it would receive the LocalAPI password). The watch
        // stream must not time out.
        let agent: ureq::Agent = ureq::Agent::config_builder().http_status_as_error(false).proxy(None).build().into();
        Self { base: format!("http://{addr}"), authorization: format!("Basic {token}"), agent }
    }

    fn get(&self, path: &str) -> Result<ureq::http::Response<ureq::Body>> {
        let response = self
            .agent
            .get(format!("{}{path}", self.base))
            .header("Sec-Tailscale", "localapi")
            .header("Authorization", &self.authorization)
            .call()
            .map_err(|error| Error(format!("LocalAPI {path}: {error}")))?;
        if response.status() != 200 {
            let status = response.status();
            let mut body = String::new();
            let _ = response.into_body().into_reader().take(512).read_to_string(&mut body);
            return Err(Error(format!("LocalAPI {path}: HTTP {status}: {}", body.trim())));
        }
        Ok(response)
    }

    /// A POST with no body (LocalAPI actions such as logout).
    fn post(&self, path: &str) -> Result<()> {
        let response = self
            .agent
            .post(format!("{}{path}", self.base))
            .header("Sec-Tailscale", "localapi")
            .header("Authorization", &self.authorization)
            .send_empty()
            .map_err(|error| Error(format!("LocalAPI {path}: {error}")))?;
        let status = response.status();
        if !status.is_success() {
            let mut body = String::new();
            let _ = response.into_body().into_reader().take(512).read_to_string(&mut body);
            return Err(Error(format!("LocalAPI {path}: HTTP {status}: {}", body.trim())));
        }
        Ok(())
    }

    /// Signs the node out: the control plane forgets the device, the node
    /// goes to NeedsLogin and keeps no login on disk.
    pub(crate) fn logout(&self) -> Result<()> {
        self.post("/localapi/v0/logout")
    }

    /// Asks the control plane for a new sign-in link (it arrives on the IPN bus).
    pub(crate) fn login_interactive(&self) -> Result<()> {
        self.post("/localapi/v0/login-interactive")
    }

    pub(crate) fn whois(&self, addr: &str) -> Result<WhoIs> {
        let path = format!("/localapi/v0/whois?addr={}", encode_query(addr));
        let response = self.get(&path)?;
        serde_json::from_reader(response.into_body().into_reader()).map_err(|error| Error(format!("whois: {error}")))
    }

    pub(crate) fn watch(&self) -> Result<Watch> {
        let mask = NOTIFY_INITIAL_STATE | NOTIFY_NO_PRIVATE_KEYS;
        let response = self.get(&format!("/localapi/v0/watch-ipn-bus?mask={mask}"))?;
        Ok(Watch { lines: BufReader::new(Box::new(response.into_body().into_reader())) })
    }
}

/// The node's IPN bus: each `next()` blocks until the node reports a change.
/// Ends when the node closes.
pub struct Watch {
    lines: BufReader<Box<dyn Read + Send>>,
}

impl Iterator for Watch {
    type Item = Notify;

    fn next(&mut self) -> Option<Notify> {
        let mut line = String::new();
        loop {
            line.clear();
            if self.lines.read_line(&mut line).ok()? == 0 {
                return None;
            }
            if let Ok(notify) = serde_json::from_str::<Notify>(line.trim()) {
                return Some(notify);
            }
        }
    }
}

fn encode_query(value: &str) -> String {
    value
        .bytes()
        .map(|byte| match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'.' | b'-' | b'_' => (byte as char).to_string(),
            _ => format!("%{byte:02X}"),
        })
        .collect()
}
