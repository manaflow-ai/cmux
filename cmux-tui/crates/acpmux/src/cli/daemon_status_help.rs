//! `daemon status --wait-adopted` in the locale's language (LC_ALL, LC_MESSAGES, LANG; English
//! unless it starts with `ja`, as `cli/sender.rs` `japanese` reads it): the after-help, and the
//! message at the timeout (bench round 5, row 10: after a restart, status read `0 live agents`
//! while the daemon still adopted them).

use std::time::Duration;

fn japanese() -> bool {
    crate::cli::sender::japanese(|k| std::env::var(k).ok())
}

/// `daemon status --help`'s closing text.
pub fn text() -> &'static str {
    if japanese() { HELP_JA } else { HELP_EN }
}

const HELP_EN: &str = "\
After `acpmux daemon restart`, the new daemon adopts the agents the earlier one left; until it
has, status says `adopting N` beside the live agents (`--json`: `adopting`).
  acpmux daemon status --wait-adopted [--timeout SECS]
      Wait until adoption ends (default at most 30 s), then print the status. At the timeout
      it prints the status, says how many it still adopts, and exits 3.";

const HELP_JA: &str = "\
`acpmux daemon restart` の後、新しいデーモンは前のデーモンが残したエージェントを引き継ぎます。
引き継ぎが終わるまで、status はライブのエージェント数の横に `adopting N` と表示します
(`--json` では `adopting`)。
  acpmux daemon status --wait-adopted [--timeout SECS]
      引き継ぎが終わるまで待ち (既定は最大 30 秒)、status を表示します。時間切れの場合は
      status を表示し、まだ引き継ぎ中の数を示して終了コード 3 で終わります。";

/// The message at `--wait-adopted`'s timeout, with `left` agents still being adopted.
pub fn still_adopting(left: u64, bound: Duration) -> String {
    let secs = bound.as_secs();
    if japanese() {
        format!("{secs} 秒待ちましたが、まだ {left} 個のエージェントを引き継ぎ中です")
    } else {
        format!("still adopting {left} after {secs} s: the restart has not reattached every agent")
    }
}
