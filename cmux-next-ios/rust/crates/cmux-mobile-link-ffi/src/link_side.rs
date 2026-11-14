//! Which device opens a web link the person opens on the phone (a link in a
//! terminal, which the Mac's shell printed).
//!
//! A public address (github.com) opens on the phone, in a browser with
//! Safari's passkeys. An address only the Mac can reach opens on the Mac, as
//! the Mac's Cmd-click does: its loopback (a dev server), a LAN or tailnet
//! host, a bare host name. Anything that is not an `http(s)` page opens nowhere.
//!
//! Hosts are read the way a browser reads them (WHATWG, the `url` crate):
//! lowercased, IDN as punycode, `2130706433` as `127.0.0.1`, userinfo apart
//! from the host, so `https://github.com@127.0.0.1/` is the Mac's loopback.

use std::net::{Ipv4Addr, Ipv6Addr};

use url::{Host, Url};

/// Where a web link opened on the phone goes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum LinkOpenSide {
    /// A public address: the phone's own browser.
    Phone,
    /// An address only the Mac can reach: a browser tab on the Mac.
    Mac,
    /// Not a web page (`javascript:`, `file:`, an app's scheme, no host).
    NotWeb,
}

/// Which device opens `url`, a link the person opened on the phone.
#[uniffi::export]
pub fn link_open_side(url: String) -> LinkOpenSide {
    classify(&url)
}

/// Name suffixes that resolve only on the Mac's own network: mDNS, MagicDNS,
/// and the private-use names routers and companies hand out.
const MAC_NETWORK_SUFFIXES: [&str; 6] =
    [".localhost", ".local", ".ts.net", ".lan", ".home.arpa", ".internal"];

pub(crate) fn classify(text: &str) -> LinkOpenSide {
    let text = text.trim();
    let Ok(url) = Url::parse(text) else {
        return if port_only(text) { LinkOpenSide::Mac } else { LinkOpenSide::NotWeb };
    };
    if !matches!(url.scheme(), "http" | "https") {
        return LinkOpenSide::NotWeb;
    }
    match url.host() {
        None => LinkOpenSide::NotWeb,
        Some(Host::Ipv4(ip)) => side_of_v4(ip),
        Some(Host::Ipv6(ip)) => side_of_v6(ip),
        Some(Host::Domain(name)) => side_of_name(name),
    }
}

/// `http://:3000/`: a port with no host, which only the Mac's browser fills in
/// (with its own loopback).
fn port_only(text: &str) -> bool {
    let lower = text.to_ascii_lowercase();
    let Some(rest) = lower.strip_prefix("http://:").or_else(|| lower.strip_prefix("https://:")) else {
        return false;
    };
    let port = rest.split(['/', '?', '#']).next().unwrap_or_default();
    !port.is_empty() && port.bytes().all(|byte| byte.is_ascii_digit()) && port.parse::<u16>().is_ok()
}

fn side_of_name(name: &str) -> LinkOpenSide {
    let name = name.strip_suffix('.').unwrap_or(name);
    if name.is_empty() {
        return LinkOpenSide::NotWeb;
    }
    // A bare host name resolves through the Mac's search domains or hosts file.
    let mac_network = MAC_NETWORK_SUFFIXES.iter().any(|suffix| name.ends_with(suffix));
    if name == "localhost" || !name.contains('.') || mac_network {
        return LinkOpenSide::Mac;
    }
    LinkOpenSide::Phone
}

fn side_of_v4(ip: Ipv4Addr) -> LinkOpenSide {
    let [a, b, ..] = ip.octets();
    // 100.64.0.0/10: carrier-grade NAT, where tailnet peers live.
    let shared = a == 100 && (64..=127).contains(&b);
    let local = ip.is_loopback() || ip.is_unspecified() || a == 0 || ip.is_link_local() || ip.is_broadcast();
    if local || ip.is_private() || shared { LinkOpenSide::Mac } else { LinkOpenSide::Phone }
}

fn side_of_v6(ip: Ipv6Addr) -> LinkOpenSide {
    if let Some(v4) = ip.to_ipv4_mapped() {
        return side_of_v4(v4);
    }
    let [first, ..] = ip.segments();
    // fc00::/7 unique local (tailnet addresses among them), fe80::/10 link-local.
    let unique_local = first & 0xfe00 == 0xfc00;
    let link_local = first & 0xffc0 == 0xfe80;
    if ip.is_loopback() || ip.is_unspecified() || unique_local || link_local {
        LinkOpenSide::Mac
    } else {
        LinkOpenSide::Phone
    }
}

#[cfg(test)]
mod tests {
    use super::{LinkOpenSide, classify};
    use LinkOpenSide::{Mac, NotWeb, Phone};

    #[test]
    fn each_address_opens_where_it_can_be_reached() {
        let table: &[(&str, LinkOpenSide)] = &[
            // Public pages: the phone.
            ("https://github.com/login", Phone),
            ("https://github.com/manaflow-ai/cmux/pull/1?tab=files#diff", Phone),
            ("http://example.com", Phone),
            ("HTTPS://GitHub.COM/Login", Phone),
            ("https://github.com./login", Phone),
            ("https://example.com:8443/a", Phone),
            ("https://user:secret@github.com/", Phone),
            ("https://bücher.de/", Phone),
            ("https://xn--bcher-kva.de/", Phone),
            ("https://8.8.8.8/", Phone),
            ("https://[2606:4700:4700::1111]/", Phone),
            ("https://100.128.0.1/", Phone),
            ("https://172.32.0.1/", Phone),
            ("https://my.local.example.com/", Phone),
            // The Mac's loopback: a dev server.
            ("http://localhost:3000/", Mac),
            ("http://LOCALHOST:3000", Mac),
            ("http://localhost./", Mac),
            ("http://app.localhost:5173/", Mac),
            ("http://127.0.0.1:8080/", Mac),
            ("http://127.1.2.3/", Mac),
            ("http://2130706433/", Mac),
            ("http://0.0.0.0:8000/", Mac),
            ("http://[::1]:3000/", Mac),
            ("http://[::]/", Mac),
            ("http://[::ffff:127.0.0.1]/", Mac),
            ("http://:3000/", Mac),
            // Userinfo never decides the host.
            ("https://github.com@127.0.0.1/", Mac),
            ("https://localhost:pw@github.com/", Phone),
            // A LAN, link-local or tailnet host.
            ("http://10.0.0.5/", Mac),
            ("http://172.16.0.1/", Mac),
            ("http://172.31.255.255/", Mac),
            ("http://192.168.1.20:8080/", Mac),
            ("http://169.254.10.1/", Mac),
            ("http://100.64.0.1/", Mac),
            ("http://100.127.255.254/", Mac),
            ("http://[fd7a:115c:a1e0::1]/", Mac),
            ("http://[fc00::1]/", Mac),
            ("http://[fe80::1]/", Mac),
            ("http://[::ffff:192.168.0.1]/", Mac),
            ("http://printer.local/", Mac),
            ("http://devbox.tail1234.ts.net:3000/", Mac),
            ("http://router.lan/", Mac),
            ("http://nas.home.arpa/", Mac),
            ("http://db.internal/", Mac),
            // A bare host name, IDN included.
            ("http://devbox:8080/", Mac),
            ("http://devbox./", Mac),
            ("http://ñ/", Mac),
            // Not a web page: nowhere.
            ("javascript:alert(1)", NotWeb),
            ("file:///etc/passwd", NotWeb),
            ("ftp://example.com/", NotWeb),
            ("mailto:a@example.com", NotWeb),
            ("cmux://tab/1", NotWeb),
            ("data:text/html,hi", NotWeb),
            ("http://", NotWeb),
            ("not a url", NotWeb),
            ("", NotWeb),
        ];
        let wrong: Vec<String> = table
            .iter()
            .filter_map(|(text, want)| {
                let got = classify(text);
                (got != *want).then(|| format!("{text:?}: got {got:?}, want {want:?}"))
            })
            .collect();
        assert!(wrong.is_empty(), "{} of {} wrong:\n{}", wrong.len(), table.len(), wrong.join("\n"));
    }
}
