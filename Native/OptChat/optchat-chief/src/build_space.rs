//! This Chief's cloud build space (`X-Cmux-Build-Space`), by cmux-tui's one rule
//! (`cmux_build_space`): a dev build's Chief owner passes `CMUX_BUILD_SPACE=dev:<slug>`, and
//! every request this crate sends to cmux Cloud carries it, so a dev build's Chief never reads
//! or changes nightly's data. A space the launcher made unusable refuses the call instead.

pub use cmux_build_space::Resolved;

/// This process's space, read once.
pub fn process() -> Resolved {
    cmux_build_space::process().map(|space| space.cloned())
}

/// `request` with `space`'s header; an unusable space is an error, and nothing is sent.
pub fn apply(request: ureq::Request, _space: &Resolved) -> Result<ureq::Request, String> {
    Ok(request)
}

/// A WebSocket upgrade's headers with `space`'s header; an unusable space is an error.
pub fn insert(
    _headers: &mut tungstenite::http::HeaderMap,
    _space: &Resolved,
) -> Result<(), String> {
    Ok(())
}

#[cfg(test)]
pub(crate) mod testing {
    //! A loopback "cloud" that answers `200 {}` and keeps each request's head.

    use std::io::{Read, Write};
    use std::net::TcpListener;
    use std::sync::{Arc, Mutex};

    pub struct Heads {
        pub base_url: String,
        heads: Arc<Mutex<Vec<String>>>,
    }

    impl Heads {
        pub fn start() -> Heads {
            let listener = TcpListener::bind("127.0.0.1:0").unwrap();
            let base_url = format!("http://{}", listener.local_addr().unwrap());
            let heads = Arc::new(Mutex::new(Vec::new()));
            let recorded = heads.clone();
            std::thread::spawn(move || {
                for mut stream in listener.incoming().flatten() {
                    let mut head = Vec::new();
                    let mut byte = [0u8; 1];
                    while !head.ends_with(b"\r\n\r\n") {
                        if stream.read(&mut byte).unwrap_or(0) == 0 {
                            break;
                        }
                        head.push(byte[0]);
                    }
                    let text = String::from_utf8_lossy(&head).to_ascii_lowercase();
                    let length = text
                        .lines()
                        .find_map(|l| l.strip_prefix("content-length:"))
                        .and_then(|v| v.trim().parse::<usize>().ok())
                        .unwrap_or(0);
                    let mut body = vec![0u8; length];
                    let _ = stream.read_exact(&mut body);
                    recorded.lock().unwrap().push(text);
                    let _ = stream.write_all(
                        b"HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: 2\r\nconnection: close\r\n\r\n{}",
                    );
                }
            });
            Heads { base_url, heads }
        }

        /// The build space header of each request so far (`None`: it had none).
        pub fn spaces(&self) -> Vec<Option<String>> {
            self.heads
                .lock()
                .unwrap()
                .iter()
                .map(|h| {
                    h.lines()
                        .find_map(|l| l.strip_prefix("x-cmux-build-space:"))
                        .map(|v| v.trim().to_owned())
                })
                .collect()
        }
    }

    pub fn dev() -> super::Resolved {
        cmux_build_space::resolve(|n| (n == "CMUX_BUILD_SPACE").then(|| "dev:my-tag".to_owned()))
    }

    pub fn unusable() -> super::Resolved {
        cmux_build_space::resolve(|n| (n == "CMUX_BUILD_SPACE").then(|| "unusable".to_owned()))
    }
}

#[cfg(test)]
mod tests {
    use super::testing::{Heads, dev, unusable};

    #[test]
    fn a_dev_chiefs_request_carries_its_space_and_a_nightly_ones_none() {
        let heads = Heads::start();
        for space in [dev(), Ok(None)] {
            let request =
                super::apply(ureq::get(&format!("{}/v1/health", heads.base_url)), &space).unwrap();
            request.call().unwrap();
        }
        assert_eq!(heads.spaces(), vec![Some("dev:my-tag".to_owned()), None]);
    }

    #[test]
    fn an_unusable_space_sends_nothing() {
        let heads = Heads::start();
        let request = ureq::get(&format!("{}/v1/health", heads.base_url));
        let error = super::apply(request, &unusable()).err().expect("refused");
        assert!(error.contains("refusing to call cmux Cloud"), "{error}");
        assert!(heads.spaces().is_empty());
    }

    #[test]
    fn a_websocket_upgrade_carries_the_space() {
        let mut headers = tungstenite::http::HeaderMap::new();
        super::insert(&mut headers, &dev()).unwrap();
        assert_eq!(headers.get("x-cmux-build-space").unwrap(), "dev:my-tag");
        assert!(super::insert(&mut tungstenite::http::HeaderMap::new(), &unusable()).is_err());
    }
}
