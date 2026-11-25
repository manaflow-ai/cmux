//! Writes an acpmux home at Leo's scale for a native bench: `chats` chats of `turns` turns each,
//! through the store (`god_fixture::write_scale_home`), and prints their ids as one JSON line.
//!
//! Leo's daemon on 2026-11-18 listed 10,789 sessions under 206 workspaces. The settle matrix
//! (scripts/cmux-next/tab_switch_frames.py `--scale leo`) writes this home into the app's fresh
//! `~/.acpmux` before its first launch, then opens 205 of the chats as workspaces:
//!
//! `cargo run --release -p acpmux --example scale_home -- HOME CHATS [TURNS] [CATALOGS]`

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let usage = "usage: scale_home HOME CHATS [TURNS] [CATALOGS]";
    let home = std::path::PathBuf::from(args.first().expect(usage));
    let number = |index: usize, default: usize| {
        args.get(index).map(|v| v.parse::<usize>().expect(usage)).unwrap_or(default)
    };
    let (chats, turns, catalogs) = (number(1, 10_789), number(2, 1), number(3, 4));
    let started = std::time::Instant::now();
    let ids = acpmux::god_fixture::write_scale_home(&home, chats, turns, catalogs)
        .unwrap_or_else(|error| panic!("scale_home {}: {error}", home.display()));
    println!(
        "{}",
        serde_json::json!({"home": home, "chats": ids.len(), "turns": turns,
            "ms": started.elapsed().as_millis() as u64, "ids": ids})
    );
}
