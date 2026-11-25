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

use std::collections::HashMap;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};

use crate::local::SERVICE_TYPE;

const TYPE_A: u16 = 1;
const TYPE_PTR: u16 = 12;
const TYPE_TXT: u16 = 16;
const TYPE_AAAA: u16 = 28;
const TYPE_SRV: u16 = 33;
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

/// A PTR question for [`SERVICE_TYPE`] with query id `id` (unicast-response
/// bit clear: the ephemeral source port alone asks for a unicast answer).
pub fn query(id: u16) -> Vec<u8> {
    let mut out = Vec::with_capacity(40);
    out.extend_from_slice(&id.to_be_bytes());
    out.extend_from_slice(&[0, 0, 0, 1, 0, 0, 0, 0, 0, 0]);
    for label in SERVICE_TYPE.trim_end_matches('.').split('.') {
        out.push(label.len() as u8);
        out.extend_from_slice(label.as_bytes());
    }
    out.push(0);
    out.extend_from_slice(&TYPE_PTR.to_be_bytes());
    out.extend_from_slice(&CLASS_IN.to_be_bytes());
    out
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
            Data::Ptr(target) if key == service => {
                if !instances.iter().any(|i| i.eq_ignore_ascii_case(&target)) {
                    instances.push(target);
                }
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
