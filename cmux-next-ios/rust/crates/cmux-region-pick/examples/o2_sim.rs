//! Simulated before/after for the central region pick (RFD 0142 O2). Every number it prints is
//! simulated from the assumptions below, not measured.
//!
//! - User network pairs: a phone in one of the metros below, its Mac in the same metro with
//!   probability 0.6, else another one at random.
//! - A leg's true round trip to a region: great-circle km / 100 times U(0.8, 1.4) (path stretch),
//!   plus, with probability `detour` per (end, region), a detour of U(20, 120) ms the estimate
//!   cannot see (backhaul, bad peering).
//! - Last mile: the phone on cellular half the time, U(25, 60) ms, else Wi-Fi U(5, 15); the Mac
//!   Wi-Fi U(5, 15).
//! - A session's relay round trip sample (a `link_stat` p50): the true round trip times U(0.9, 1.3).
//! - Before: today's placement, the least great-circle estimate (`placement.ts`). After: [`pick`]
//!   fed every earlier session's sample, 20 sessions per pair.
//!
//! `cargo run -p cmux-region-pick --example o2_sim`

use cmux_region_pick::{Learned, N, observe, pick};

const CENTRES: [(f64, f64); N] = [
    (37.4, -121.9),
    (39.0, -77.5),
    (-23.5, -46.6),
    (50.5, 3.0),
    (52.2, 21.0),
    (22.3, 114.2),
    (-33.9, 151.2),
    (-26.2, 28.0),
    (25.2, 55.3),
];

const METROS: [(f64, f64); 24] = [
    (40.7, -74.0),  // New York
    (37.8, -122.4), // San Francisco
    (34.1, -118.2), // Los Angeles
    (41.9, -87.6),  // Chicago
    (47.6, -122.3), // Seattle
    (30.3, -97.7),  // Austin
    (43.7, -79.4),  // Toronto
    (19.4, -99.1),  // Mexico City
    (-23.5, -46.6), // Sao Paulo
    (-34.6, -58.4), // Buenos Aires
    (51.5, -0.1),   // London
    (48.9, 2.4),    // Paris
    (52.5, 13.4),   // Berlin
    (59.3, 18.1),   // Stockholm
    (41.0, 29.0),   // Istanbul
    (35.7, 139.7),  // Tokyo
    (37.6, 127.0),  // Seoul
    (1.35, 103.8),  // Singapore
    (12.97, 77.6),  // Bangalore
    (-33.9, 151.2), // Sydney
    (-36.8, 174.8), // Auckland
    (-26.2, 28.0),  // Johannesburg
    (6.5, 3.4),     // Lagos
    (25.2, 55.3),   // Dubai
];

struct Rng(u64);
impl Rng {
    fn next(&mut self) -> f64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        (self.0 >> 11) as f64 / (1u64 << 53) as f64
    }
    fn range(&mut self, lo: f64, hi: f64) -> f64 {
        lo + (hi - lo) * self.next()
    }
    fn below(&mut self, n: usize) -> usize {
        ((self.next() * n as f64) as usize).min(n - 1)
    }
}

fn km(a: (f64, f64), b: (f64, f64)) -> f64 {
    let rad = std::f64::consts::PI / 180.0;
    let (dlat, dlon) = ((b.0 - a.0) * rad, (b.1 - a.1) * rad);
    let h = (dlat / 2.0).sin().powi(2) + (a.0 * rad).cos() * (b.0 * rad).cos() * (dlon / 2.0).sin().powi(2);
    2.0 * 6371.0 * h.sqrt().min(1.0).asin()
}

struct Out {
    regret: f64,
    best: f64,
    tail_regret: f64,
    rtt: f64,
}

fn run(detour: f64, pairs: usize, sessions: usize, seed: u64) -> (Out, Out) {
    let mut rng = Rng(seed);
    let (mut before, mut after) = (
        Out { regret: 0.0, best: 0.0, tail_regret: 0.0, rtt: 0.0 },
        Out { regret: 0.0, best: 0.0, tail_regret: 0.0, rtt: 0.0 },
    );
    let tail = sessions.min(10);
    for _ in 0..pairs {
        let phone = METROS[rng.below(METROS.len())];
        let mac = if rng.next() < 0.6 { phone } else { METROS[rng.below(METROS.len())] };
        let last_mile = (if rng.next() < 0.5 { rng.range(25.0, 60.0) } else { rng.range(5.0, 15.0) })
            + rng.range(5.0, 15.0);
        let mut truth = [0.0; N];
        let mut estimate = [None; N];
        for r in 0..N {
            let leg = |end: (f64, f64), rng: &mut Rng| {
                let d = km(end, CENTRES[r]) / 100.0;
                let mut t = d * rng.range(0.8, 1.4);
                if rng.next() < detour {
                    t += rng.range(20.0, 120.0);
                }
                (d, t)
            };
            let (ea, ta) = leg(phone, &mut rng);
            let (eb, tb) = leg(mac, &mut rng);
            truth[r] = ta + tb + last_mile;
            estimate[r] = Some(ea + eb);
        }
        let best = truth.iter().copied().fold(f64::INFINITY, f64::min);
        let geo = (0..N).min_by(|&a, &b| estimate[a].unwrap().total_cmp(&estimate[b].unwrap())).unwrap();
        let mut learned: [Option<Learned>; N] = [None; N];
        let mut current = None;
        for s in 0..sessions {
            let p = pick(&estimate, &learned, current, Some(geo));
            let r = p.region.unwrap();
            current = Some(r);
            for (out, chosen) in [(&mut before, geo), (&mut after, r)] {
                let regret = truth[chosen] - best;
                out.regret += regret;
                out.rtt += truth[chosen];
                out.best += f64::from(u8::from(regret < 1e-9));
                if s >= sessions - tail {
                    out.tail_regret += regret;
                }
            }
            let sample = truth[r] * rng.range(0.9, 1.3);
            learned[r] = observe(learned[r], sample);
        }
    }
    let n = (pairs * sessions) as f64;
    for o in [&mut before, &mut after] {
        o.regret /= n;
        o.rtt /= n;
        o.best /= n / 100.0;
        o.tail_regret /= (pairs * tail) as f64;
    }
    (before, after)
}

fn main() {
    println!("simulated: 2000 network pairs x 20 sessions each, seed fixed");
    println!(
        "{:>7} | {:>26} | {:>26} | {:>21} | {:>21}",
        "detour",
        "mean relay RTT ms (b -> a)",
        "mean regret ms (b -> a)",
        "best region % (b -> a)",
        "last-10 regret (b -> a)"
    );
    for detour in [0.0, 0.05, 0.15, 0.30] {
        let (b, a) = run(detour, 2000, 20, 0x9e37_79b9_7f4a_7c15);
        println!(
            "{:>7.2} | {:>11.1} -> {:>11.1} | {:>11.1} -> {:>11.1} | {:>8.1} -> {:>8.1} | {:>8.1} -> {:>8.1}",
            detour, b.rtt, a.rtt, b.regret, a.regret, b.best, a.best, b.tail_regret, a.tail_regret
        );
    }
}
