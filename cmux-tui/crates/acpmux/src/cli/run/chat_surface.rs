//! Where `acpmux new` shows a new chat when it does not detach: in the cmux
//! app's agent chat (GUI, the default) or in acpmux's terminal TUI. Agents
//! that ran `acpmux new` without `-d` opened the TUI in their own terminal
//! where the person wanted the app's chat, so the GUI is the default and
//! the TUI stays one flag (`--tui`) or one setting away.

use serde_json::Value;

/// The cmux.json key: `"gui"` (default) or `"tui"`. Read at each new chat.
pub(crate) const SETTING: &str = "agents.defaultChatSurface";

/// Where a new chat shows.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum ChatSurface {
    /// The cmux app's agent chat (`cmux agent open`).
    Gui,
    /// acpmux's terminal TUI in the calling terminal.
    Tui,
}

/// The surface the settings document names; the GUI when it names none or
/// an unknown value.
pub(crate) fn from_settings(doc: Option<&Value>) -> ChatSurface {
    let named = doc.and_then(|doc| crate::user_settings::value(doc, SETTING));
    match named.as_ref().and_then(Value::as_str).map(str::trim) {
        Some(value) if value.eq_ignore_ascii_case("tui") => ChatSurface::Tui,
        _ => ChatSurface::Gui,
    }
}

/// The surface the settings file names now (an unreadable file: the GUI).
pub(crate) fn current() -> ChatSurface {
    match crate::user_settings::read() {
        crate::user_settings::Settings::Parsed(doc) => from_settings(Some(&doc)),
        _ => ChatSurface::Gui,
    }
}

/// `--tui` or `--gui` for one command, else the setting.
pub(crate) fn choose(tui: bool, gui: bool, setting: ChatSurface) -> ChatSurface {
    match (tui, gui) {
        (true, _) => ChatSurface::Tui,
        (false, true) => ChatSurface::Gui,
        (false, false) => setting,
    }
}

#[cfg(test)]
mod tests;
