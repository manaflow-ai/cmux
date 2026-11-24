//! The pure parts of `cmux-mobile-path-probe` (src/bin/cmux-mobile-path-probe.rs):
//! latency summaries (percentiles and loss), the great-circle round-trip floor
//! between two sites, STUN Binding messages for timing a TURN server, and the
//! markdown table of a run.

use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};

use serde::Serialize;

/// One measured series: each sample in milliseconds, `None` for a lost one
/// (no answer within the probe's bound).
#[derive(Debug, Clone, Default, PartialEq, Serialize)]
pub struct Summary {
    /// Samples taken (answered and lost).
    pub n: usize,
    pub lost: usize,
    /// `lost / n` in percent (0 for an empty series).
    pub loss_pct: f64,
    pub min: Option<f64>,
    pub p50: Option<f64>,
    pub p95: Option<f64>,
    pub p99: Option<f64>,
    pub max: Option<f64>,
    pub mean: Option<f64>,
}

/// Nearest-rank percentile of sorted `values` (`p` in 0..=100): the smallest
/// value with at least `p` percent of the values at or below it.
pub fn percentile(sorted: &[f64], p: f64) -> Option<f64> {
    if sorted.is_empty() {
        return None;
    }
    let rank = ((p / 100.0) * sorted.len() as f64).ceil() as usize;
    Some(sorted[rank.clamp(1, sorted.len()) - 1])
}

/// Rounded to 0.1 ms.
fn tenth(value: f64) -> f64 {
    (value * 10.0).round() / 10.0
}

impl Summary {
    pub fn of(samples: &[Option<f64>]) -> Self {
        let mut answered: Vec<f64> = samples.iter().flatten().copied().filter(|v| v.is_finite()).collect();
        answered.sort_by(f64::total_cmp);
        let n = samples.len();
        let lost = n - answered.len();
        let at = |p| percentile(&answered, p).map(tenth);
        Self {
            n,
            lost,
            loss_pct: if n == 0 { 0.0 } else { tenth(lost as f64 * 100.0 / n as f64) },
            min: answered.first().copied().map(tenth),
            p50: at(50.0),
            p95: at(95.0),
            p99: at(99.0),
            max: answered.last().copied().map(tenth),
            mean: (!answered.is_empty()).then(|| tenth(answered.iter().sum::<f64>() / answered.len() as f64)),
        }
    }
}

/// A place on Earth, for the round-trip floor between two sites.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Site {
    pub label: String,
    pub lat: f64,
    pub lon: f64,
}

impl Site {
    /// `label:lat,lon` (`us-west1:45.60,-121.18`).
    pub fn parse(text: &str) -> Option<Self> {
        let (label, coords) = text.rsplit_once(':')?;
        let (lat, lon) = coords.split_once(',')?;
        let (lat, lon) = (lat.trim().parse().ok()?, lon.trim().parse().ok()?);
        if !(-90.0..=90.0).contains(&lat) || !(-180.0..=180.0).contains(&lon) {
            return None;
        }
        Some(Self { label: label.to_owned(), lat, lon })
    }
}

/// Mean Earth radius (km).
const EARTH_KM: f64 = 6371.0;
/// Light in fiber: about 2/3 of c, in km per millisecond.
pub const FIBER_KM_PER_MS: f64 = 299_792.458 * 2.0 / 3.0 / 1000.0;

/// Great-circle distance in km (haversine).
pub fn great_circle_km(a: &Site, b: &Site) -> f64 {
    let (lat1, lat2) = (a.lat.to_radians(), b.lat.to_radians());
    let dlat = lat2 - lat1;
    let dlon = (b.lon - a.lon).to_radians();
    let h = (dlat / 2.0).sin().powi(2) + lat1.cos() * lat2.cos() * (dlon / 2.0).sin().powi(2);
    2.0 * EARTH_KM * h.sqrt().asin()
}

/// The round trip a straight fiber between `a` and `b` would take: no route
/// can beat it, so a path's RTT over this is its detour.
pub fn rtt_floor_ms(a: &Site, b: &Site) -> f64 {
    2.0 * great_circle_km(a, b) / FIBER_KM_PER_MS
}

/// STUN (RFC 5389).
pub mod stun {
    use super::*;

    pub const MAGIC: u32 = 0x2112_A442;
    const BINDING_REQUEST: u16 = 0x0001;
    const BINDING_SUCCESS: u16 = 0x0101;
    const XOR_MAPPED_ADDRESS: u16 = 0x0020;
    const MAPPED_ADDRESS: u16 = 0x0001;
    const SOFTWARE: u16 = 0x8022;

    /// A Binding request with no attributes.
    pub fn binding_request(transaction: [u8; 12]) -> [u8; 20] {
        let mut message = [0u8; 20];
        message[..2].copy_from_slice(&BINDING_REQUEST.to_be_bytes());
        // Length 0: no attributes.
        message[4..8].copy_from_slice(&MAGIC.to_be_bytes());
        message[8..].copy_from_slice(&transaction);
        message
    }

    /// What a Binding success response says.
    #[derive(Debug, Clone, PartialEq, Eq, Default)]
    pub struct BindingResponse {
        /// This side's address as the server saw it.
        pub mapped: Option<SocketAddr>,
        /// The server's SOFTWARE attribute, if it sent one.
        pub software: Option<String>,
    }

    /// `datagram` as the Binding success response to `transaction`, or
    /// `None` when it is anything else (another transaction, an error, junk).
    pub fn parse_binding_response(datagram: &[u8], transaction: [u8; 12]) -> Option<BindingResponse> {
        if datagram.len() < 20 {
            return None;
        }
        let kind = u16::from_be_bytes([datagram[0], datagram[1]]);
        let length = usize::from(u16::from_be_bytes([datagram[2], datagram[3]]));
        if kind != BINDING_SUCCESS
            || datagram[4..8] != MAGIC.to_be_bytes()
            || datagram[8..20] != transaction
            || datagram.len() < 20 + length
        {
            return None;
        }
        let mut response = BindingResponse::default();
        let mut rest = &datagram[20..20 + length];
        while rest.len() >= 4 {
            let kind = u16::from_be_bytes([rest[0], rest[1]]);
            let len = usize::from(u16::from_be_bytes([rest[2], rest[3]]));
            let value = rest.get(4..4 + len)?;
            match kind {
                XOR_MAPPED_ADDRESS => response.mapped = address(value, true, transaction).or(response.mapped),
                MAPPED_ADDRESS if response.mapped.is_none() => {
                    response.mapped = address(value, false, transaction);
                }
                SOFTWARE => response.software = Some(String::from_utf8_lossy(value).into_owned()),
                _ => {}
            }
            rest = rest.get(4 + len.div_ceil(4) * 4..).unwrap_or_default();
        }
        Some(response)
    }

    fn address(value: &[u8], xor: bool, transaction: [u8; 12]) -> Option<SocketAddr> {
        let family = *value.get(1)?;
        let mut port = u16::from_be_bytes([*value.get(2)?, *value.get(3)?]);
        let cookie = MAGIC.to_be_bytes();
        if xor {
            port ^= (MAGIC >> 16) as u16;
        }
        let ip = match family {
            0x01 => {
                let mut octets: [u8; 4] = value.get(4..8)?.try_into().ok()?;
                if xor {
                    octets.iter_mut().zip(cookie).for_each(|(o, k)| *o ^= k);
                }
                IpAddr::V4(Ipv4Addr::from(octets))
            }
            0x02 => {
                let mut octets: [u8; 16] = value.get(4..20)?.try_into().ok()?;
                if xor {
                    let key = cookie.iter().chain(transaction.iter());
                    octets.iter_mut().zip(key).for_each(|(o, k)| *o ^= k);
                }
                IpAddr::V6(Ipv6Addr::from(octets))
            }
            _ => return None,
        };
        Some(SocketAddr::new(ip, port))
    }
}

/// One row of the markdown table: a path or a step and what it measured.
#[derive(Debug, Clone, Default, PartialEq, Serialize)]
pub struct Row {
    pub name: String,
    /// The path the link reported (`direct`, `turn`, `turn-tls`), if a link.
    pub path: Option<String>,
    pub setup: Option<Summary>,
    pub rtt: Option<Summary>,
    pub note: String,
}

fn cell(value: Option<f64>) -> String {
    value.map_or_else(|| "-".to_owned(), |v| format!("{v:.1}"))
}

/// The run as a markdown table: setup p50/p95, RTT p50/p95/p99, loss.
pub fn markdown(rows: &[Row]) -> String {
    let mut out = String::from(
        "| path | reported | setup p50 | setup p95 | RTT p50 | RTT p95 | RTT p99 | loss | n | note |\n\
         | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |\n",
    );
    for row in rows {
        let setup = row.setup.clone().unwrap_or_default();
        let rtt = row.rtt.clone().unwrap_or_default();
        let loss = if row.rtt.is_some() { format!("{:.1}%", rtt.loss_pct) } else { "-".to_owned() };
        let n = if row.rtt.is_some() { rtt.n } else { setup.n };
        out.push_str(&format!(
            "| {} | {} | {} | {} | {} | {} | {} | {} | {} | {} |\n",
            row.name,
            row.path.as_deref().unwrap_or("-"),
            cell(setup.p50),
            cell(setup.p95),
            cell(rtt.p50),
            cell(rtt.p95),
            cell(rtt.p99),
            loss,
            n,
            row.note.replace('|', "/"),
        ));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nearest_rank_percentiles() {
        let values: Vec<f64> = (1..=100).map(f64::from).collect();
        assert_eq!(percentile(&values, 50.0), Some(50.0));
        assert_eq!(percentile(&values, 95.0), Some(95.0));
        assert_eq!(percentile(&values, 99.0), Some(99.0));
        assert_eq!(percentile(&values, 100.0), Some(100.0));
        assert_eq!(percentile(&values, 0.0), Some(1.0));
        assert_eq!(percentile(&[7.0], 99.0), Some(7.0));
        assert_eq!(percentile(&[], 50.0), None);
        // Ten values: p95 and p99 are both the largest.
        let ten: Vec<f64> = (1..=10).map(f64::from).collect();
        assert_eq!(percentile(&ten, 50.0), Some(5.0));
        assert_eq!(percentile(&ten, 95.0), Some(10.0));
    }

    #[test]
    fn summary_counts_loss_and_ignores_order() {
        let samples = [Some(3.0), None, Some(1.0), Some(2.0), None];
        let summary = Summary::of(&samples);
        assert_eq!(summary.n, 5);
        assert_eq!(summary.lost, 2);
        assert_eq!(summary.loss_pct, 40.0);
        assert_eq!(summary.min, Some(1.0));
        assert_eq!(summary.p50, Some(2.0));
        assert_eq!(summary.max, Some(3.0));
        assert_eq!(summary.mean, Some(2.0));
    }

    #[test]
    fn summary_of_nothing_or_all_lost() {
        let empty = Summary::of(&[]);
        assert_eq!((empty.n, empty.lost, empty.loss_pct, empty.p50), (0, 0, 0.0, None));
        let lost = Summary::of(&[None, None]);
        assert_eq!((lost.n, lost.lost, lost.loss_pct, lost.p99, lost.mean), (2, 2, 100.0, None, None));
    }

    #[test]
    fn summary_rounds_to_a_tenth() {
        let summary = Summary::of(&[Some(1.234), Some(1.26)]);
        assert_eq!(summary.min, Some(1.2));
        assert_eq!(summary.max, Some(1.3));
    }

    #[test]
    fn rtt_floor_between_known_sites() {
        let dalles = Site::parse("us-west1:45.60,-121.18").unwrap();
        let ashburn = Site::parse("us-east4:39.04,-77.49").unwrap();
        let km = great_circle_km(&dalles, &ashburn);
        assert!((3500.0..3700.0).contains(&km), "{km}");
        // 2 * ~3600 km / ~200 km per ms: about 36 ms.
        let floor = rtt_floor_ms(&dalles, &ashburn);
        assert!((35.0..37.0).contains(&floor), "{floor}");
        assert_eq!(rtt_floor_ms(&dalles, &dalles), 0.0);
    }

    #[test]
    fn site_parse_rejects_bad_input() {
        assert_eq!(Site::parse("x:1,2").unwrap().label, "x");
        assert!(Site::parse("x:91,0").is_none());
        assert!(Site::parse("x:1").is_none());
        assert!(Site::parse("1,2").is_none());
        // A label may hold colons: the coordinates follow the last one.
        assert_eq!(Site::parse("gcp:us-west1:45.6,-121.2").unwrap().label, "gcp:us-west1");
    }

    #[test]
    fn stun_binding_round_trip() {
        let transaction = [7u8; 12];
        let request = stun::binding_request(transaction);
        assert_eq!(&request[..4], &[0, 1, 0, 0]);
        assert_eq!(&request[4..8], &stun::MAGIC.to_be_bytes());

        // A success response: XOR-MAPPED-ADDRESS 203.0.113.5:40000, SOFTWARE "cf".
        let mut body = Vec::new();
        let port = 40000u16 ^ (stun::MAGIC >> 16) as u16;
        let mut ip = [203u8, 0, 113, 5];
        ip.iter_mut().zip(stun::MAGIC.to_be_bytes()).for_each(|(o, k)| *o ^= k);
        body.extend_from_slice(&[0x00, 0x20, 0x00, 0x08, 0x00, 0x01]);
        body.extend_from_slice(&port.to_be_bytes());
        body.extend_from_slice(&ip);
        body.extend_from_slice(&[0x80, 0x22, 0x00, 0x02, b'c', b'f', 0, 0]);
        let mut response = vec![0x01, 0x01];
        response.extend_from_slice(&(body.len() as u16).to_be_bytes());
        response.extend_from_slice(&stun::MAGIC.to_be_bytes());
        response.extend_from_slice(&transaction);
        response.extend_from_slice(&body);

        let parsed = stun::parse_binding_response(&response, transaction).unwrap();
        assert_eq!(parsed.mapped, Some("203.0.113.5:40000".parse().unwrap()));
        assert_eq!(parsed.software.as_deref(), Some("cf"));
        // Another transaction's answer, or a request, is not ours.
        assert!(stun::parse_binding_response(&response, [8u8; 12]).is_none());
        assert!(stun::parse_binding_response(&request, transaction).is_none());
        assert!(stun::parse_binding_response(&response[..10], transaction).is_none());
    }

    #[test]
    fn markdown_rows() {
        let rows = [
            Row {
                name: "wg-relay".into(),
                path: Some("turn".into()),
                setup: Some(Summary::of(&[Some(100.0), Some(120.0)])),
                rtt: Some(Summary::of(&[Some(10.0), Some(12.0), None, Some(11.0)])),
                note: "a|b".into(),
            },
            Row { name: "ice".into(), setup: Some(Summary::of(&[Some(40.0)])), ..Row::default() },
        ];
        let table = markdown(&rows);
        let lines: Vec<&str> = table.lines().collect();
        assert_eq!(lines.len(), 4);
        assert_eq!(lines[2], "| wg-relay | turn | 100.0 | 120.0 | 11.0 | 12.0 | 12.0 | 25.0% | 4 | a/b |");
        assert_eq!(lines[3], "| ice | - | 40.0 | 40.0 | - | - | - | - | 1 |  |");
    }
}
