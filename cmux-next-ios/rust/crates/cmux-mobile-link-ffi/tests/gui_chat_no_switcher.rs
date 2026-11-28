//! Detector: a GUI chat on the phone never grows the Chat | Terminal switcher again
//! (cmuxterm-hq docs/handbook/phone-chat-refuses-what-the-mac-does.md).
//!
//! Leo, 2026-11-18: "I thought we removed the top right toggle for now for the, like, GUI
//! to terminal switch when you're in a GUI chat, because it doesn't really work right now."
//!
//! The floating capsule went in cmux#44819, and the page menu row is off by default and
//! absent on a GUI chat since cmux#45446 (`terminal_chat.rs`
//! `a_chat_no_terminal_runs_shows_no_toggle`). Leo still saw it because no cnx-ios INTERNAL
//! upload had succeeded since before both merged. This scan fails if the control comes back
//! in any phone source.

use std::path::{Path, PathBuf};

/// Controls that must not exist in the phone's Swift sources.
const FORBIDDEN: &[(&str, &str)] = &[
    ("TerminalChatToggleControl", "the Chat | Terminal switcher was removed from agent pages (cmux#44819)"),
    ("ChatTerminalToggle", "the Chat | Terminal switcher was removed from agent pages (cmux#44819)"),
];

fn swift_files(dir: &Path, out: &mut Vec<PathBuf>) {
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            swift_files(&path, out);
        } else if path.extension().is_some_and(|ext| ext == "swift") {
            out.push(path);
        }
    }
}

#[test]
fn no_phone_source_draws_the_chat_terminal_switcher() {
    let ios = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..");
    let roots = ["CmuxMobileKit/Sources", "App", "UITests"].map(|root| ios.join(root));
    let mut files = Vec::new();
    for root in &roots {
        swift_files(root, &mut files);
    }
    assert!(
        files.len() > 100,
        "found only {} Swift files under {}: the scan must read the phone's sources",
        files.len(),
        ios.display()
    );
    let mut found = Vec::new();
    for file in &files {
        let Ok(text) = std::fs::read_to_string(file) else { continue };
        for (needle, why) in FORBIDDEN {
            if text.contains(needle) {
                found.push(format!("{}: `{needle}`: {why}", file.display()));
            }
        }
    }
    assert!(found.is_empty(), "the GUI chat switcher is back:\n{}", found.join("\n"));
}
