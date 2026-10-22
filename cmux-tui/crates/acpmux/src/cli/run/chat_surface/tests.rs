use serde_json::json;

use super::{ChatSurface, SETTING, choose, from_settings};

/// Agents opened the TUI when a person wanted the app's chat: with no
/// setting a new chat opens in the cmux app (GUI).
#[test]
fn a_new_chat_opens_in_the_app_by_default() {
    assert_eq!(from_settings(None), ChatSurface::Gui);
    assert_eq!(from_settings(Some(&json!({}))), ChatSurface::Gui);
    assert_eq!(choose(false, false, ChatSurface::Gui), ChatSurface::Gui);
}

/// The setting picks the TUI; an unknown value keeps the GUI default.
#[test]
fn the_setting_picks_the_tui() {
    let tui = json!({"agents": {"defaultChatSurface": "tui"}});
    assert_eq!(SETTING, "agents.defaultChatSurface");
    assert_eq!(from_settings(Some(&tui)), ChatSurface::Tui);
    let dotted = json!({"agents.defaultChatSurface": "tui"});
    assert_eq!(from_settings(Some(&dotted)), ChatSurface::Tui);
    let odd = json!({"agents": {"defaultChatSurface": "terminal-ish"}});
    assert_eq!(from_settings(Some(&odd)), ChatSurface::Gui);
}

/// `--tui` and `--gui` win over the setting for one command.
#[test]
fn a_flag_wins_over_the_setting() {
    assert_eq!(choose(true, false, ChatSurface::Gui), ChatSurface::Tui);
    assert_eq!(choose(false, true, ChatSurface::Tui), ChatSurface::Gui);
    assert_eq!(choose(false, false, ChatSurface::Tui), ChatSurface::Tui);
}
