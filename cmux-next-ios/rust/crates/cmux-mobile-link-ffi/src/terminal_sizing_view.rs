//! The phone's view of a shared terminal's size (cmux-next-ios/PROTOCOL.md
//! "Terminal sizing policy (host-size-policy-v1)"): who each viewer is, the
//! size it asks for, who sets the grid and why, and the Priority Order list
//! with its device tokens.
//!
//! These rules were a Swift copy in CmuxMobileModel's `TerminalSizing.swift`
//! (`TerminalSizingPresentation`, `HostSizePolicy` token rules). Swift now
//! hands the daemon's size state here and only renders what comes back
//! (Leo, 2026-11-25: "i was wondering why we even have swift at all";
//! Lawrence, 2026-11-02: "move as much from swift into rust as possible").
//!
//! Every function is a pure function of its input and linear in the number
//! of viewers and order tokens (the order is capped at [`MAX_ORDER`]).

/// The token of the Mac the phone is connected to in the priority order
/// (`mobile.terminalSizingOrder`).
pub const MAC_TOKEN: &str = "mac";
const DEVICE_PREFIX: &str = "device:";
/// The most tokens a stored priority order keeps.
pub const MAX_ORDER: usize = 32;
const MAX_DEVICE_ID_BYTES: usize = 128;

/// A terminal grid in cells.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Record)]
pub struct SizingGrid {
    pub cols: u32,
    pub rows: u32,
}

/// One attached view of a terminal, as the Mac's daemon publishes it.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SizingParticipant {
    pub id: String,
    pub device_kind: String,
    pub device_name: Option<String>,
    pub display_name: Option<String>,
    pub device_id: Option<String>,
    /// The size this viewer asks for; none while its terminal is off screen.
    pub viewport: Option<SizingGrid>,
}

/// What the view is drawn from: the daemon's size state (when there is one)
/// and who this phone and this Mac are.
#[derive(Debug, Clone, Default, PartialEq, Eq, uniffi::Record)]
pub struct SizingViewInput {
    /// False while the daemon has published no size state: no rows, no reason.
    pub has_state: bool,
    /// `latest`, `smallest`, `largest`, `priority`, `fixed`, `held`, `priority-fallback`.
    pub reason: String,
    /// The participants that set a dimension.
    pub owners: Vec<String>,
    pub participants: Vec<SizingParticipant>,
    /// This phone's participant id on the terminal.
    pub self_participant: Option<String>,
    /// The participant ids of the Mac the phone is connected to.
    pub mac_participants: Vec<String>,
    /// This phone's device id.
    pub this_device_id: Option<String>,
}

/// One Connected Devices row.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SizingRow {
    pub id: String,
    pub title: String,
    /// `120×39`, or "Not showing it".
    pub detail: String,
    pub sets_size: bool,
    /// An SF Symbol name.
    pub symbol: String,
}

/// One Priority Order row.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SizingOrderRow {
    pub token: String,
    pub title: String,
    pub symbol: String,
}

/// A desktop viewer: a Mac, a cmux-tui frontend, or the desktop app on Linux
/// or Windows.
#[uniffi::export]
pub fn terminal_sizing_is_desktop(device_kind: String) -> bool {
    is_desktop(&device_kind)
}

fn is_desktop(kind: &str) -> bool {
    matches!(kind, "mac" | "tui" | "linux" | "windows")
}

/// The priority-order token of a device id.
#[uniffi::export]
pub fn host_size_device_token(device_id: String) -> String {
    format!("{DEVICE_PREFIX}{device_id}")
}

/// The device id a token names; none for the Mac token or a malformed one.
#[uniffi::export]
pub fn host_size_token_device_id(token: String) -> Option<String> {
    device_id_of(&token).map(str::to_owned)
}

fn device_id_of(token: &str) -> Option<&str> {
    token.strip_prefix(DEVICE_PREFIX).filter(|id| !id.is_empty())
}

/// A token the daemon accepts: `mac`, or `device:` and 1 to 128 bytes of
/// `[A-Za-z0-9_.:-]`.
#[uniffi::export]
pub fn host_size_token_valid(token: String) -> bool {
    token_valid(&token)
}

fn token_valid(token: &str) -> bool {
    if token == MAC_TOKEN {
        return true;
    }
    let Some(id) = device_id_of(token) else { return false };
    id.len() <= MAX_DEVICE_ID_BYTES
        && id.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'.' | b':' | b'-'))
}

/// The most tokens a stored priority order keeps.
#[uniffi::export]
pub fn host_size_max_order() -> u32 {
    MAX_ORDER as u32
}

/// `120×40`.
#[uniffi::export]
pub fn terminal_sizing_grid_label(grid: SizingGrid) -> String {
    format!("{}×{}", grid.cols, grid.rows)
}

impl SizingViewInput {
    fn is_this_mac(&self, p: &SizingParticipant) -> bool {
        self.mac_participants.contains(&p.id)
    }

    fn is_this_phone(&self, p: &SizingParticipant) -> bool {
        self.self_participant.as_deref() == Some(p.id.as_str())
            || (self.this_device_id.is_some()
                && p.device_id == self.this_device_id
                && !is_desktop(&p.device_kind))
    }

    fn title(&self, p: &SizingParticipant) -> String {
        if self.is_this_mac(p) {
            return "This Mac".into();
        }
        if self.is_this_phone(p) {
            return "This iPhone".into();
        }
        if let Some(name) = p.device_name.as_ref().or(p.display_name.as_ref()) {
            return name.clone();
        }
        match p.device_kind.as_str() {
            "mac" => "Another Mac",
            "iphone" => "An iPhone",
            "ipad" => "An iPad",
            "tui" => "A terminal",
            _ => "Another device",
        }
        .into()
    }

    fn token(&self, p: &SizingParticipant) -> Option<String> {
        if self.is_this_mac(p) {
            return Some(MAC_TOKEN.into());
        }
        p.device_id.clone().map(host_size_device_token)
    }

    /// The viewer a device token names, never one of this Mac's panes.
    fn participant_for(&self, token: &str) -> Option<&SizingParticipant> {
        let id = device_id_of(token)?;
        self.participants.iter().find(|p| p.device_id.as_deref() == Some(id) && !self.is_this_mac(p))
    }

    fn is_this_device_token(&self, token: &str) -> bool {
        device_id_of(token).is_some_and(|id| self.this_device_id.as_deref() == Some(id))
    }

    fn order_title(&self, token: &str) -> String {
        if token == MAC_TOKEN {
            return "This Mac".into();
        }
        if self.is_this_device_token(token) {
            return "This iPhone".into();
        }
        self.participant_for(token).map_or_else(|| "Another device".into(), |p| self.title(p))
    }

    fn order_symbol(&self, token: &str) -> String {
        if token == MAC_TOKEN {
            return "laptopcomputer".into();
        }
        if self.is_this_device_token(token) {
            return "iphone".into();
        }
        self.participant_for(token).map_or("display", |p| symbol(&p.device_kind)).into()
    }
}

fn symbol(kind: &str) -> &'static str {
    match kind {
        "mac" | "linux" | "windows" => "laptopcomputer",
        "iphone" => "iphone",
        "ipad" => "ipad",
        "tui" => "apple.terminal",
        _ => "display",
    }
}

/// "A", "A and B", "A, B, and C".
fn joined_list(items: &[String]) -> String {
    match items {
        [] => String::new(),
        [one] => one.clone(),
        [a, b] => format!("{a} and {b}"),
        [rest @ .., last] => format!("{}, and {last}", rest.join(", ")),
    }
}

/// The name of a viewer as the phone shows it: "This Mac", "This iPhone",
/// its device or display name, or what kind of device it is.
#[uniffi::export]
pub fn terminal_sizing_title(input: SizingViewInput, participant: SizingParticipant) -> String {
    input.title(&participant)
}

/// The Connected Devices rows: every viewer, the size it asks for and
/// whether it sets the grid. None without a size state.
#[uniffi::export]
pub fn terminal_sizing_rows(input: SizingViewInput) -> Vec<SizingRow> {
    if !input.has_state {
        return Vec::new();
    }
    input
        .participants
        .iter()
        .map(|p| SizingRow {
            id: p.id.clone(),
            title: input.title(p),
            detail: p.viewport.map_or_else(|| "Not showing it".into(), terminal_sizing_grid_label),
            sets_size: input.owners.contains(&p.id),
            symbol: symbol(&p.device_kind).into(),
        })
        .collect()
}

/// Why the grid has its size; none without a size state.
#[uniffi::export]
pub fn terminal_sizing_reason(input: SizingViewInput) -> Option<String> {
    if !input.has_state {
        return None;
    }
    let owners: Vec<String> =
        input.participants.iter().filter(|p| input.owners.contains(&p.id)).map(|p| input.title(p)).collect();
    let named = (!owners.is_empty()).then(|| joined_list(&owners));
    Some(match (input.reason.as_str(), named) {
        ("smallest", n) => {
            n.map_or("Fits the smallest viewer".into(), |n| format!("Fits the smallest viewer: {n}"))
        }
        ("largest", n) => {
            n.map_or("Fits the largest viewer".into(), |n| format!("Fits the largest viewer: {n}"))
        }
        ("fixed", _) => "Fixed size".into(),
        ("held", _) => "Kept from the last viewer".into(),
        ("priority-fallback", n) => {
            n.map_or("Set by the device active last".into(), |n| format!("Set by {n}, active last"))
        }
        ("priority", n) => {
            n.map_or("Set by the first device in order".into(), |n| format!("Set by {n}, first in order"))
        }
        (_, n) => n.map_or("Set by the device active last".into(), |n| format!("Set by {n}")),
    })
}

/// The priority list to show: the stored order first, then every viewer not
/// in it (this Mac and this iPhone first), so a reorder ranks every device in
/// sight. Stored tokens of absent devices keep their slots; invalid and
/// repeated tokens are dropped and the list never passes [`MAX_ORDER`].
#[uniffi::export]
pub fn terminal_sizing_order_rows(input: SizingViewInput, order: Vec<String>) -> Vec<SizingOrderRow> {
    let mut tokens: Vec<String> = Vec::new();
    let mut add = |token: Option<String>| {
        if let Some(token) = token
            && tokens.len() < MAX_ORDER
            && token_valid(&token)
            && !tokens.contains(&token)
        {
            tokens.push(token);
        }
    };
    let this_device = input.this_device_id.clone().map(host_size_device_token);
    // This Mac and this iPhone always have a place, ahead of devices the
    // stored order does not rank.
    let pinned: Vec<String> = std::iter::once(MAC_TOKEN.to_owned()).chain(this_device.clone()).collect();
    let stored: Vec<String> = order.into_iter().filter(|t| token_valid(t)).collect();
    let room = MAX_ORDER.saturating_sub(pinned.iter().filter(|t| !stored.contains(t)).count());
    for token in stored.into_iter().take(room) {
        add(Some(token));
    }
    add(Some(MAC_TOKEN.to_owned()));
    add(this_device);
    if input.has_state {
        for p in &input.participants {
            add(input.token(p));
        }
    }
    tokens
        .into_iter()
        .map(|token| SizingOrderRow {
            title: input.order_title(&token),
            symbol: input.order_symbol(&token),
            token,
        })
        .collect()
}

/// The order after moving the rows at `from` to before `to` (SwiftUI's
/// `onMove`). Out-of-range indices are ignored, never a crash.
#[uniffi::export]
pub fn terminal_sizing_reordered(tokens: Vec<String>, from: Vec<u32>, to: u32) -> Vec<String> {
    let mut from: Vec<usize> = from.into_iter().map(|i| i as usize).filter(|&i| i < tokens.len()).collect();
    from.sort_unstable();
    from.dedup();
    let to = (to as usize).min(tokens.len());
    let moving: Vec<String> = from.iter().map(|&i| tokens[i].clone()).collect();
    let mut rest: Vec<String> = tokens
        .into_iter()
        .enumerate()
        .filter(|(i, _)| from.binary_search(i).is_err())
        .map(|(_, t)| t)
        .collect();
    let before = from.iter().filter(|&&i| i < to).count();
    let at = (to - before).min(rest.len());
    rest.splice(at..at, moving);
    rest
}

#[cfg(test)]
#[path = "terminal_sizing_view_tests.rs"]
mod tests;
