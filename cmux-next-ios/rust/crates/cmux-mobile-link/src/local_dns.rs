//! A one-shot mDNS query for the local hub (RFC 6762 §5.1, §6.7), the wire
//! half: the packet a phone or a desktop sends, and what it reads back.
//!
//! Why one-shot: a query sent from an ephemeral port gets its answer by
//! unicast, at once, with the SRV, TXT and address records in the same
//! packet. A full mDNS browser (port 5353) instead waits out the responder's
//! shared-record delay and its once-per-second multicast limit: in netlab a
//! Mac that had just announced (or answered another browser) kept a phone
//! waiting about a second for its next query. Measured: `local.sh` row a.
//!
//! No sockets here: the caller sends [`query`] to 224.0.0.251:5353 /
//! [ff02::fb]:5353 on each interface and feeds each reply to [`parse`].
//!
//! The Mac's half of the same speed-up for a full browser ([`asks_unicast`],
//! [`answer`]): NWBrowser's first question is a QU question from port 5353
//! (RFC 6762 §5.4, unicast response requested). mdns-sd treats it as an
//! ordinary multicast question: a 10-50 ms shared-record delay, then a
//! multicast answer dropped if the record went out in the last second (its
//! §6 rate limit: the Mac's own two announcements, or any other browser's
//! answer), so the phone waited for its next question, a second or more
//! later. The host answers such a question itself, by unicast, at once
//! (`cmux-mobile-host` `local_link.rs`). Measured there:
//! `nwbrowser_qu_question_first_ad_ms`.

use std::collections::HashMap;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};

use crate::local::SERVICE_TYPE;

const TYPE_A: u16 = 1;
const TYPE_PTR: u16 = 12;
const TYPE_TXT: u16 = 16;
const TYPE_AAAA: u16 = 28;
const TYPE_SRV: u16 = 33;
const TYPE_ANY: u16 = 255;
const CLASS_IN: u16 = 1;

/// The mDNS group and port.
pub const MDNS_V4: Ipv4Addr = Ipv4Addr::new(224, 0, 0, 251);
pub const MDNS_V6: Ipv6Addr = Ipv6Addr::new(0xff02, 0, 0, 0, 0, 0, 0, 0xfb);
pub const MDNS_PORT: u16 = 5353;

/// One service instance an answer named: its TXT pairs, the SRV port and the
/// addresses of the SRV target (from the same packet).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Found {
    pub instance: String,
    pub txt: Vec<(String, String)>,
    pub port: u16,
    pub addresses: Vec<IpAddr>,
}

/// The class bit that asks for a unicast response in a question (QU), and
/// flushes the cache in a record (RFC 6762 §5.4, §10.2).
const CLASS_TOP_BIT: u16 = 0x8000;
const FLAGS_RESPONSE: [u8; 2] = [0x84, 0x00];
/// RFC 6762 §10: host-name records (SRV, A, AAAA) live 120 s, others 75 min.
const HOST_TTL: u32 = 120;
const OTHER_TTL: u32 = 4500;

/// A PTR question for [`SERVICE_TYPE`] with query id `id` (unicast-response
/// bit clear: the ephemeral source port alone asks for a unicast answer).
pub fn query(id: u16) -> Vec<u8> {
    query_with(id, false)
}

/// [`query`] with the unicast-response (QU) bit as `unicast_response` says:
/// what NWBrowser sends first, from port 5353.
pub fn query_with(id: u16, unicast_response: bool) -> Vec<u8> {
    let mut out = Vec::with_capacity(40);
    out.extend_from_slice(&id.to_be_bytes());
    out.extend_from_slice(&[0, 0, 0, 1, 0, 0, 0, 0, 0, 0]);
    for label in SERVICE_TYPE.trim_end_matches('.').split('.') {
        out.push(label.len() as u8);
        out.extend_from_slice(label.as_bytes());
    }
    out.push(0);
    out.extend_from_slice(&TYPE_PTR.to_be_bytes());
    let class = if unicast_response { CLASS_IN | CLASS_TOP_BIT } else { CLASS_IN };
    out.extend_from_slice(&class.to_be_bytes());
    out
}

/// Whether `packet` is a query with a QU question (unicast response
/// requested) for [`SERVICE_TYPE`]'s PTR records (or ANY). Malformed: no.
pub fn asks_unicast(packet: &[u8]) -> bool {
    let u16_at =
        |at: usize| -> Option<u16> { Some(u16::from_be_bytes([*packet.get(at)?, *packet.get(at + 1)?])) };
    let asks = || -> Option<bool> {
        // Queries only (QR clear), standard opcode.
        if packet.get(2)? & 0xf8 != 0 {
            return Some(false);
        }
        let service = SERVICE_TYPE.trim_end_matches('.');
        let mut at = 12;
        for _ in 0..u16_at(4)? {
            let (owner, next) = name(packet, at)?;
            let (kind, class) = (u16_at(next)?, u16_at(next + 2)?);
            at = next + 4;
            if class & CLASS_TOP_BIT != 0
                && class & !CLASS_TOP_BIT == CLASS_IN
                && (kind == TYPE_PTR || kind == TYPE_ANY)
                && owner.eq_ignore_ascii_case(service)
            {
                return Some(true);
            }
        }
        Some(false)
    };
    asks().unwrap_or(false)
}

/// The full answer to a [`SERVICE_TYPE`] question for one instance, as a
/// unicast reply to a QU question (RFC 6762 §6): the PTR answer, and the
/// SRV, TXT and address records as additionals, so the phone resolves the
/// hub from this one packet. `instance` and `host` are the names the Mac's
/// mDNS responder registered (`<instance>._cmux-link._tcp.local`,
/// `<host>.local`, no trailing dot). No cache-flush bit: this reply adds to
/// what the responder multicasts, it must not evict any of it.
pub fn answer(
    instance: &str,
    host: &str,
    port: u16,
    txt: &[(String, String)],
    addresses: &[IpAddr],
) -> Vec<u8> {
    let service = SERVICE_TYPE.trim_end_matches('.');
    let instance_name = format!("{instance}.{service}");
    let additionals = 2 + addresses.len();
    let mut out = Vec::with_capacity(256);
    out.extend_from_slice(&[0, 0]);
    out.extend_from_slice(&FLAGS_RESPONSE);
    out.extend_from_slice(&[0, 0, 0, 1, 0, 0]);
    out.extend_from_slice(&(additionals as u16).to_be_bytes());
    let mut ptr = Vec::new();
    put_name(&mut ptr, &instance_name);
    put_record(&mut out, service, TYPE_PTR, OTHER_TTL, &ptr);
    let mut srv = vec![0, 0, 0, 0];
    srv.extend_from_slice(&port.to_be_bytes());
    put_name(&mut srv, host);
    put_record(&mut out, &instance_name, TYPE_SRV, HOST_TTL, &srv);
    let mut text = Vec::new();
    for (key, value) in txt {
        let entry = format!("{key}={value}");
        let bytes = &entry.as_bytes()[..entry.len().min(255)];
        text.push(bytes.len() as u8);
        text.extend_from_slice(bytes);
    }
    if text.is_empty() {
        text.push(0);
    }
    put_record(&mut out, &instance_name, TYPE_TXT, OTHER_TTL, &text);
    for address in addresses {
        match address {
            IpAddr::V4(v4) => put_record(&mut out, host, TYPE_A, HOST_TTL, &v4.octets()),
            IpAddr::V6(v6) => put_record(&mut out, host, TYPE_AAAA, HOST_TTL, &v6.octets()),
        }
    }
    out
}

fn put_name(out: &mut Vec<u8>, name: &str) {
    for label in name.trim_end_matches('.').split('.').filter(|l| !l.is_empty()) {
        let label = &label.as_bytes()[..label.len().min(63)];
        out.push(label.len() as u8);
        out.extend_from_slice(label);
    }
    out.push(0);
}

fn put_record(out: &mut Vec<u8>, owner: &str, kind: u16, ttl: u32, rdata: &[u8]) {
    put_name(out, owner);
    out.extend_from_slice(&kind.to_be_bytes());
    out.extend_from_slice(&CLASS_IN.to_be_bytes());
    out.extend_from_slice(&ttl.to_be_bytes());
    out.extend_from_slice(&(rdata.len() as u16).to_be_bytes());
    out.extend_from_slice(rdata);
}

/// The [`SERVICE_TYPE`] instances a reply describes in full (SRV with a port
/// and at least one address). Malformed packets yield nothing.
pub fn parse(packet: &[u8]) -> Vec<Found> {
    parse_records(packet).map(assemble).unwrap_or_default()
}

enum Data {
    Ptr(String),
    Srv { port: u16, target: String },
    Txt(Vec<(String, String)>),
    Addr(IpAddr),
    Other,
}

struct Record {
    name: String,
    data: Data,
}

fn assemble(records: Vec<Record>) -> Vec<Found> {
    let service = SERVICE_TYPE.trim_end_matches('.').to_ascii_lowercase();
    let mut instances: Vec<String> = Vec::new();
    let mut srv: HashMap<String, (u16, String)> = HashMap::new();
    let mut txt: HashMap<String, Vec<(String, String)>> = HashMap::new();
    let mut addresses: HashMap<String, Vec<IpAddr>> = HashMap::new();
    for record in records {
        let key = record.name.to_ascii_lowercase();
        match record.data {
            Data::Ptr(target)
                if key == service && !instances.iter().any(|i| i.eq_ignore_ascii_case(&target)) =>
            {
                instances.push(target);
            }
            Data::Srv { port, target } => {
                srv.insert(key, (port, target.to_ascii_lowercase()));
            }
            Data::Txt(pairs) => {
                txt.insert(key, pairs);
            }
            Data::Addr(ip) => {
                let list = addresses.entry(key).or_default();
                if !list.contains(&ip) {
                    list.push(ip);
                }
            }
            _ => {}
        }
    }
    instances
        .into_iter()
        .filter_map(|instance| {
            let key = instance.to_ascii_lowercase();
            let (port, target) = srv.get(&key)?.clone();
            let addresses = addresses.get(&target).cloned().unwrap_or_default();
            if addresses.is_empty() {
                return None;
            }
            Some(Found { txt: txt.get(&key).cloned().unwrap_or_default(), instance, port, addresses })
        })
        .collect()
}

fn parse_records(packet: &[u8]) -> Option<Vec<Record>> {
    let u16_at =
        |at: usize| -> Option<u16> { Some(u16::from_be_bytes([*packet.get(at)?, *packet.get(at + 1)?])) };
    // Only responses (QR set).
    if packet.get(2)? & 0x80 == 0 {
        return None;
    }
    let questions = u16_at(4)?;
    let records = u16_at(6)? as usize + u16_at(8)? as usize + u16_at(10)? as usize;
    let mut at = 12;
    for _ in 0..questions {
        at = name(packet, at)?.1 + 4;
    }
    let mut out = Vec::with_capacity(records.min(64));
    for _ in 0..records {
        let (owner, next) = name(packet, at)?;
        let kind = u16_at(next)?;
        let length = u16_at(next + 8)? as usize;
        let start = next + 10;
        let rdata = packet.get(start..start + length)?;
        let data = match kind {
            TYPE_PTR => Data::Ptr(name(packet, start)?.0),
            TYPE_SRV if length >= 7 => {
                Data::Srv { port: u16_at(start + 4)?, target: name(packet, start + 6)?.0 }
            }
            TYPE_TXT => Data::Txt(txt_pairs(rdata)),
            TYPE_A if length == 4 => {
                Data::Addr(IpAddr::V4(Ipv4Addr::new(rdata[0], rdata[1], rdata[2], rdata[3])))
            }
            TYPE_AAAA if length == 16 => {
                let bytes: [u8; 16] = rdata.try_into().ok()?;
                Data::Addr(IpAddr::V6(Ipv6Addr::from(bytes)))
            }
            _ => Data::Other,
        };
        out.push(Record { name: owner, data });
        at = start + length;
    }
    Some(out)
}

/// The name at `at` (dotted, no trailing dot) and the offset just past it.
fn name(packet: &[u8], mut at: usize) -> Option<(String, usize)> {
    let mut labels: Vec<String> = Vec::new();
    let mut end = None;
    // A pointer loop or a deep chain is malformed.
    for _ in 0..64 {
        let length = *packet.get(at)? as usize;
        match length {
            0 => {
                return Some((labels.join("."), end.unwrap_or(at + 1)));
            }
            l if l & 0xc0 == 0xc0 => {
                let target = ((l & 0x3f) << 8) | *packet.get(at + 1)? as usize;
                end.get_or_insert(at + 2);
                at = target;
            }
            l if l < 64 => {
                let label = packet.get(at + 1..at + 1 + l)?;
                labels.push(String::from_utf8_lossy(label).into_owned());
                at += 1 + l;
            }
            _ => return None,
        }
    }
    None
}

fn txt_pairs(rdata: &[u8]) -> Vec<(String, String)> {
    let mut out = Vec::new();
    let mut at = 0;
    while let Some(&length) = rdata.get(at) {
        let Some(entry) = rdata.get(at + 1..at + 1 + length as usize) else { break };
        let entry = String::from_utf8_lossy(entry);
        if let Some((key, value)) = entry.split_once('=') {
            out.push((key.to_owned(), value.to_owned()));
        } else if !entry.is_empty() {
            out.push((entry.into_owned(), String::new()));
        }
        at += 1 + length as usize;
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn put_name(out: &mut Vec<u8>, name: &str) {
        for label in name.split('.') {
            out.push(label.len() as u8);
            out.extend_from_slice(label.as_bytes());
        }
        out.push(0);
    }

    fn record(out: &mut Vec<u8>, owner: &[u8], kind: u16, rdata: &[u8]) {
        out.extend_from_slice(owner);
        out.extend_from_slice(&kind.to_be_bytes());
        out.extend_from_slice(&[0x80, 1, 0, 0, 0, 10]);
        out.extend_from_slice(&(rdata.len() as u16).to_be_bytes());
        out.extend_from_slice(rdata);
    }

    /// A reply as mdns-sd's legacy unicast sends it: the question echoed, the
    /// PTR answer, SRV/TXT/A/AAAA additionals, names compressed.
    fn reply() -> Vec<u8> {
        let mut p = vec![0x12, 0x34, 0x84, 0, 0, 1, 0, 1, 0, 0, 0, 4];
        let service_at = p.len() as u16;
        put_name(&mut p, "_cmux-link._tcp.local");
        p.extend_from_slice(&[0, 12, 0, 1]);
        let pointer = |at: u16| [0xc0 | (at >> 8) as u8, at as u8];
        // PTR: _cmux-link._tcp.local -> cmux-abc._cmux-link._tcp.local
        let instance_at = p.len() as u16 + 12;
        let mut rdata = vec![8];
        rdata.extend_from_slice(b"cmux-abc");
        rdata.extend_from_slice(&pointer(service_at));
        record(&mut p, &pointer(service_at), TYPE_PTR, &rdata);
        // SRV: port 7420, target cmux-abc.local
        let mut srv = vec![0, 0, 0, 0, 0x1c, 0xfc];
        put_name(&mut srv, "cmux-abc.local");
        record(&mut p, &pointer(instance_at), TYPE_SRV, &srv);
        let mut txt = Vec::new();
        for entry in ["id=mac-1", "v=1", "k=00ff"] {
            txt.push(entry.len() as u8);
            txt.extend_from_slice(entry.as_bytes());
        }
        record(&mut p, &pointer(instance_at), TYPE_TXT, &txt);
        let mut host = Vec::new();
        put_name(&mut host, "cmux-abc.local");
        record(&mut p, &host, TYPE_A, &[192, 168, 11, 10]);
        let v6: Ipv6Addr = "fe80::1".parse().unwrap();
        record(&mut p, &host, TYPE_AAAA, &v6.octets());
        p
    }

    #[test]
    fn reads_a_unicast_reply_in_full() {
        let found = parse(&reply());
        assert_eq!(found.len(), 1);
        let found = &found[0];
        assert_eq!(found.instance, "cmux-abc._cmux-link._tcp.local");
        assert_eq!(found.port, 7420);
        assert_eq!(found.txt[0], ("id".to_owned(), "mac-1".to_owned()));
        assert_eq!(
            found.addresses,
            vec![IpAddr::from([192, 168, 11, 10]), "fe80::1".parse::<IpAddr>().unwrap()]
        );
    }

    #[test]
    fn query_is_one_ptr_question() {
        let q = query(7);
        assert_eq!(&q[..6], &[0, 7, 0, 0, 0, 1]);
        assert_eq!(name(&q, 12).unwrap().0, "_cmux-link._tcp.local");
        // Our own query is not a reply.
        assert!(parse(&q).is_empty());
    }

    #[test]
    fn qu_questions_are_told_apart() {
        assert!(asks_unicast(&query_with(0, true)));
        assert!(!asks_unicast(&query_with(0, false)));
        // A reply is not a question, nor is a QU question for another type.
        let mut reply = query_with(0, true);
        reply[2] = 0x84;
        assert!(!asks_unicast(&reply));
        let mut other = vec![0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0];
        super::put_name(&mut other, "_airplay._tcp.local");
        other.extend_from_slice(&[0, 12, 0x80, 1]);
        assert!(!asks_unicast(&other));
        for cut in 0..query_with(0, true).len() {
            assert!(!asks_unicast(&query_with(0, true)[..cut]));
        }
    }

    #[test]
    fn our_answer_reads_back_in_full() {
        let txt = vec![("id".to_owned(), "mac-1".to_owned()), ("v".to_owned(), "1".to_owned())];
        let addresses = vec![IpAddr::from([192, 168, 1, 4]), "fe80::2".parse().unwrap()];
        let packet = answer("cmux-mac1", "cmux-mac1.local", 7420, &txt, &addresses);
        let found = parse(&packet);
        assert_eq!(
            found,
            vec![Found { instance: "cmux-mac1._cmux-link._tcp.local".into(), txt, port: 7420, addresses }]
        );
        // A response, id 0, no question: what RFC 6762 §6 asks of a unicast
        // reply to a QU question from port 5353.
        assert_eq!(&packet[..6], &[0, 0, 0x84, 0, 0, 0]);
    }

    #[test]
    fn malformed_packets_yield_nothing() {
        let good = reply();
        for cut in 0..good.len() {
            let _ = parse(&good[..cut]);
        }
        // A pointer to itself.
        let mut looped = vec![0, 0, 0x84, 0, 0, 1, 0, 0, 0, 0, 0, 0];
        looped.extend_from_slice(&[0xc0, 12, 0, 12, 0, 1]);
        assert!(parse(&looped).is_empty());
    }
}
