//! The phone's kill switch file for Swift (`cmux_mobile_link::pieces`; cmux-next-ios/SECURITY.md
//! "What the phone takes remotely").
//!
//! Swift passes the app's bundle identifier, whether it is a DEBUG build, and a folder of the
//! app's own; everything else is decided here and below. A build that reads no switch file
//! (every build but cmux INTERNAL today, the App Store app included) gets `reads: false`: no
//! request is made and the folder is neither read nor created.

use std::path::{Path, PathBuf};

use cmux_mobile_link::pieces;

/// One piece switched off, back to the fallback built into the app.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PieceOff {
    /// `markdown-web`, `terminal-agent-cli-changes`, `terminal-predictive-echo`.
    pub piece: String,
    /// The file's reason (an issue or PR); may be empty.
    pub reason: String,
}

/// What the app holds after a read of the switch file.
#[derive(Debug, Clone, Default, PartialEq, Eq, uniffi::Record)]
pub struct PiecesReading {
    /// Whether this build reads a switch file at all.
    pub reads: bool,
    /// The pieces switched off. Every other piece is on.
    pub off: Vec<PieceOff>,
    /// The serial of the last file taken; 0 when none was.
    pub serial: u64,
    /// `taken`, `no_file`, `fresh`, a refusal's code, or `off` for a build that reads none.
    pub verdict: String,
}

fn reading(reading: pieces::Reading) -> PiecesReading {
    PiecesReading {
        reads: true,
        off: reading.off.into_iter().map(|(piece, reason)| PieceOff { piece, reason }).collect(),
        serial: reading.serial,
        verdict: reading.verdict,
    }
}

fn not_reading() -> PiecesReading {
    PiecesReading { verdict: "off".to_owned(), ..PiecesReading::default() }
}

fn now() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |since| since.as_secs())
}

/// The switches this build last took, from `dir` alone: what a launch applies before a piece
/// first shows. No network, no write; two small file reads.
#[uniffi::export]
pub fn pieces_load(dir: String, bundle_id: String, debug: bool) -> PiecesReading {
    match pieces::channel(&bundle_id, debug) {
        Some(channel) => reading(pieces::load(Path::new(&dir), channel)),
        None => not_reading(),
    }
}

/// One check of the published switch file, after launch and on foreground: at most one GET (none
/// when the server answered in the last 15 minutes), the state and the log kept in `dir`. Never
/// fails: a read that fails or a refused file answers with what the phone already holds.
#[uniffi::export]
pub async fn pieces_check(dir: String, bundle_id: String, debug: bool) -> PiecesReading {
    let Some(channel) = pieces::channel(&bundle_id, debug) else {
        return not_reading();
    };
    let dir = PathBuf::from(dir);
    crate::on_runtime(async move { reading(pieces::check(&dir, channel, now()).await) }).await
}

/// The last `count` lines of the log in `dir`, oldest first, each one JSON object: what was
/// read, what was refused and why, and which pieces it left off.
#[uniffi::export]
pub fn pieces_log(dir: String, count: u32) -> Vec<String> {
    pieces::log_tail(Path::new(&dir), count as usize)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_build_that_reads_no_file_touches_nothing() {
        let dir = tempfile::tempdir().unwrap();
        let state = dir.path().join("cmux-pieces");
        let text = state.display().to_string();
        for (bundle, debug) in [
            ("com.cmux.app", false),
            ("dev.cmux.app.beta", false),
            ("dev.cmux.app.demo", false),
            ("dev.cmux.app.dev", true),
            ("dev.cmux.app.internal", true),
        ] {
            let reading = pieces_load(text.clone(), bundle.to_owned(), debug);
            assert_eq!(reading, PiecesReading { verdict: "off".to_owned(), ..Default::default() });
        }
        assert!(!state.exists());
    }

    #[tokio::test]
    async fn a_check_of_a_build_that_reads_no_file_asks_nothing() {
        let dir = tempfile::tempdir().unwrap();
        let state = dir.path().join("cmux-pieces");
        let reading = pieces_check(state.display().to_string(), "com.cmux.app".to_owned(), false).await;
        assert!(!reading.reads);
        assert!(reading.off.is_empty());
        assert!(!state.exists());
    }

    #[test]
    fn the_internal_build_reads_its_folder() {
        let dir = tempfile::tempdir().unwrap();
        let text = dir.path().display().to_string();
        let reading = pieces_load(text.clone(), "dev.cmux.app.internal".to_owned(), false);
        assert!(reading.reads);
        assert_eq!((reading.off.len(), reading.serial, reading.verdict.as_str()), (0, 0, "no_file"));
        assert!(pieces_log(text, 5).is_empty());
    }
}
