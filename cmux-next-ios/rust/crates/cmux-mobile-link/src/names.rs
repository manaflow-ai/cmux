//! The phone link's capability names, declared once (hq RFD 0047 item 5).
//!
//! Each name is a `pub const`; [`ALL`] carries every one with who says it and what it means.
//! PROTOCOL.md's "Capabilities" table is printed from [`ALL`] (the test below compares it;
//! `CMUX_UPDATE_LINK_NAMES=1 cargo test -p cmux-mobile-link names` rewrites it).
//! Swift still types these by hand (follow-up).

/// Who puts a capability on the wire.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Side {
    /// The Mac's hostd lists it in the `version` service's `capabilities`, for the phone.
    Host,
    /// The cmux-tui daemon owns it; the link's hostd declares it in `set-client-info` or
    /// checks it in `identify`.
    Daemon,
}

impl Side {
    fn label(self) -> &'static str {
        match self {
            Self::Host => "hostd `version`",
            Self::Daemon => "cmux-tui daemon",
        }
    }
}

/// A service implemented by the Mac host for a channel opened by the phone.
///
/// Keep this registry in the link crate, alongside the capability declarations. The
/// host dispatch and lockstep manifest generator can consume the same exhaustive list,
/// so adding a service cannot silently leave one of those surfaces behind. The
/// private link park service (`_link.park`) is handled by the framing layer and is
/// intentionally separate.
macro_rules! host_services {
    ($(($variant:ident, $wire:literal)),+ $(,)?) => {
        #[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
        pub enum HostService {
            $($variant),+
        }

        impl HostService {
            pub const ALL: &'static [Self] = &[$(Self::$variant),+];

            pub const fn as_str(self) -> &'static str {
                match self {
                    $(Self::$variant => $wire),+
                }
            }

            pub fn parse(wire: &str) -> Option<Self> {
                match wire {
                    $($wire => Some(Self::$variant),)+
                    _ => None,
                }
            }
        }
    };
}

host_services! {
    (Auth, "auth"),
    (Echo, "echo"),
    (Daemon, "daemon"),
    (Chief, "chief"),
    (Acpmux, "acpmux"),
    (CloudDirectory, "cloud-directory"),
    (CatchUp, "catch-up"),
    (CloudAcpmux, "cloud-acpmux"),
    (File, "file"),
    (FilePreview, "file-preview"),
    (Upload, "upload"),
    (Bundle, "bundle"),
    (Version, "version"),
    (Machine, "machine"),
    (NeedsYou, "needs-you"),
    (PairRequests, "pair-requests"),
    (Appearance, "appearance"),
    (AppearanceWallpaper, "appearance-wallpaper"),
    (Browser, "browser"),
    (Surface, "surface"),
    (Localhost, "localhost"),
    (PhoneFrames, "phone-frames"),
    (Tabs, "tabs"),
    (Lan, "lan"),
}

/// One capability name and its one-line meaning.
#[derive(Clone, Copy, Debug)]
pub struct Capability {
    pub name: &'static str,
    pub side: Side,
    pub meaning: &'static str,
    /// Wire names introduced or gated by this capability.
    pub wire_names: &'static [&'static str],
}

pub const REMOVAL: &str = "removal-v1";
pub const FILE_PREVIEW: &str = "file-preview-v1";
pub const LOCALHOST_FORWARD: &str = "localhost-forward-v1";
pub const CLOUD_DIRECTORY: &str = "cloud-directory-v1";
pub const CLOUD_ACPMUX: &str = "cloud-acpmux-v1";
pub const NEEDS_YOU: &str = "needs-you-v1";
pub const APPEARANCE: &str = "appearance-v1";
pub const PAIR_REQUESTS: &str = "pair-requests-v1";
pub const PHONE_FRAMES: &str = "phone-frames-v1";
pub const TAB_SNAPSHOTS: &str = "tab-snapshots-v1";
pub const BUNDLE: &str = "bundle-v1";
pub const BROWSER_STREAM: &str = "browser-stream-v1";
pub const BROWSER_VIDEO_TRACK: &str = "browser-video-track-v1";
pub const SURFACE_STREAM: &str = "surface-stream-v1";
pub const CLOUD_DESKTOP: &str = "cloud-desktop-v1";
pub const MAILBOX_SEND: &str = "mailbox-send-v1";
pub const MAC_DISPLAY: &str = "mac-display-v1";

pub const CLOUD_MOBILE_CHAT: &str = "cloud-mobile-chat-v1";
pub const CONVERSATION_TABS: &str = "conversation-tabs-v1";
pub const PAGE_TABS: &str = "page-tabs-v1";
pub const AGENT_SESSION_TABS: &str = "agent-session-tabs-v1";
pub const SEND_EXPECT_AGENT: &str = "send-expect-agent-v1";
pub const AGENT_CLI_HYBRID: &str = "agent-cli-hybrid-v1";
pub const AGENT_CLI_HYBRID_LEAN: &str = "agent-cli-hybrid-v2";
pub const TERMINAL_SHELL_LINES: &str = "terminal-shell-lines-v1";
pub const ATTACH_OUTPUT_COALESCE: &str = "attach-output-coalesce-v1";
pub const TERMINAL_FULL_SCREEN_FRAMES: &str = "terminal-full-screen-frames-v1";

/// What the phone's terminal session declares in `set-client-info` for the lean stream
/// (Settings, Transport, Agent CLI Screen Changes): agent CLIs and shells as lean cell deltas,
/// a full-screen program too (its modes as bytes), and coalesced PTY bytes for the rest.
/// `CmuxMobileLive` `DaemonTerminalSession.capabilities` declares this list.
pub const TERMINAL_LEAN_STREAM: &[&str] = &[
    AGENT_CLI_HYBRID,
    AGENT_CLI_HYBRID_LEAN,
    TERMINAL_SHELL_LINES,
    ATTACH_OUTPUT_COALESCE,
    TERMINAL_FULL_SCREEN_FRAMES,
];

const fn host(name: &'static str, meaning: &'static str, wire_names: &'static [&'static str]) -> Capability {
    Capability { name, side: Side::Host, meaning, wire_names }
}

const fn daemon(
    name: &'static str,
    meaning: &'static str,
    wire_names: &'static [&'static str],
) -> Capability {
    Capability { name, side: Side::Daemon, meaning, wire_names }
}

/// Every capability name the link speaks, hostd's in the order it advertises them.
pub const ALL: &[Capability] = &[
    host(
        REMOVAL,
        "After its owner removes it (signaling 4002 `removed`) the Mac stays off until iPhone connections are allowed again on the Mac; without it the Mac may add itself back.",
        // Removal changes host behavior after a 4002. The Worker sends that code to any host.
        &["control:version.capabilities/removal-v1"],
    ),
    host(
        FILE_PREVIEW,
        "`file-preview` sends a size metadata frame before the file bytes, so the phone can check free storage first.",
        &["service:file-preview", "param:file-preview#path", "field:file-preview#size"],
    ),
    host(
        LOCALHOST_FORWARD,
        "(2026-10-30) The host serves `localhost`: a phone browser tab reaches a port on the Mac's loopback.",
        &["service:localhost", "param:localhost#port"],
    ),
    host(
        CLOUD_DIRECTORY,
        "(2026-11-01) The host lists the owner's authenticated Cloud machines through the Mac carrier (`cloud-directory`).",
        &["service:cloud-directory"],
    ),
    host(
        CLOUD_ACPMUX,
        "(2026-11-01) The host drives an owned Cloud machine's agents through the Mac carrier (`cloud-acpmux`).",
        &["service:cloud-acpmux", "param:cloud-acpmux#machine_id", "param:cloud-acpmux#team_id"],
    ),
    host(
        NEEDS_YOU,
        "The host serves `needs-you`: the Mac app's own open Feed requests.",
        &["service:needs-you"],
    ),
    host(
        APPEARANCE,
        "(2026-11-12) The host serves `appearance` and `appearance-wallpaper`: the Mac's theme and wallpaper.",
        &["service:appearance", "service:appearance-wallpaper", "param:appearance-wallpaper#id"],
    ),
    host(
        PAIR_REQUESTS,
        "The host serves `pair-requests`: a paired device answers a pairing request waiting on this Mac.",
        &[
            "service:pair-requests",
            "control:pair-requests/list",
            "control:pair-requests/answer",
            "param:pair-requests#action",
            "param:pair-requests#deviceId",
            "param:pair-requests#fingerprint",
            "param:pair-requests#allow",
        ],
    ),
    host(
        PHONE_FRAMES,
        "The host serves `phone-frames`: the phone's terminal scroll frame times, logged to `phone-frames.jsonl` on the Mac.",
        &["service:phone-frames", "control:phone-frames/tui", "control:phone-frames/scrollback"],
    ),
    host(
        TAB_SNAPSHOTS,
        "(2026-11-22) The host serves `tabs`: every tab's title, favicon, thumbnail or terminal screen text, each picture sent once by hash and then only changes.",
        &["service:tabs"],
    ),
    host(
        MAILBOX_SEND,
        "(2026-11-24) The Mac's mailbox takes `send` (a chat message) and `compose` (a queue action) items, held up to 24 hours and applied once, in each phone's order: a phone routes a send to the mailbox only to a Mac that listed it on its last link.",
        // The items themselves are sealed; on the wire it adds the queue position (`seq`), which an
        // older hub omits and an older Mac ignores.
        &["field:mailbox.items#seq"],
    ),
    host(
        BUNDLE,
        "(2026-11-24) The host serves `bundle`: an attachment upload (`put`) or file open (`get`) as sealed content-defined chunks, so a file the far end already holds costs one round trip and its manifest.",
        &["service:bundle", "param:bundle#op"],
    ),
    host(
        BROWSER_STREAM,
        "The host streams browser tabs (`browser`); listed only when the Mac has a browser host.",
        &["service:browser", "param:browser#tab", "param:browser#url"],
    ),
    host(
        BROWSER_VIDEO_TRACK,
        "With `browser-stream-v1`: `browser {\"video\":\"track\"}` carries the page's video on the media lane (WebRTC, and WireGuard since 2026-10-14).",
        &["param:browser#video", "param:browser#video_tag"],
    ),
    host(
        SURFACE_STREAM,
        "(2026-10-22) The host streams the Mac's phone tabs' simulators (`surface`); listed only when the Mac app streams simulators.",
        &["service:surface", "param:surface#tab", "param:surface#video", "param:surface#video_tag"],
    ),
    host(
        CLOUD_DESKTOP,
        "(2026-11-02) `surface` also streams an owned Cloud machine's desktop, view only, on the key `c~<machine_id>~<team_id>`.",
        // The `c~...~...` form is a distinct value of `surface.tab`. Keep it separate from
        // ordinary simulator tabs so a new desktop path cannot accidentally be treated as one.
        &["control:surface.tab/c~"],
    ),
    host(
        MAC_DISPLAY,
        "(2026-11-23) `surface` also streams this Mac's own display as rd/1 on the link, view only, on the key `d~<display>` (CGDirectDisplayID, 0 the main display); served while Share This Mac is on.",
        // Like `c~`, the `d~...` form is a distinct value of `surface.tab`.
        &["control:surface.tab/d~"],
    ),
    daemon(
        CLOUD_MOBILE_CHAT,
        "On a `cloud-acpmux` carrier hostd requires the Cloud daemon's `identify` to list it before declaring it (phone prompt restrictions).",
        &["control:set-client-info.capabilities/cloud-mobile-chat-v1"],
    ),
    daemon(
        CONVERSATION_TABS,
        "Declared in `set-client-info`: conversation tabs read as `conversation` with their record, not `browser`.",
        &["field:list-workspaces#conversation"],
    ),
    daemon(
        PAGE_TABS,
        "Declared in `set-client-info`: page tabs read as `conversation` with their `page` (a phone tab is a simulator tab).",
        &["field:list-workspaces#page"],
    ),
    daemon(
        AGENT_SESSION_TABS,
        "Declared in `set-client-info` on a `cloud-acpmux` carrier: agent session tabs read with their session source.",
        &["field:list-workspaces#agent_session"],
    ),
    daemon(
        SEND_EXPECT_AGENT,
        "In `identify`: a notification reply to an agent types text and Return only while that agent waits at its prompt (#24205).",
        &["param:send#expect_agent"],
    ),
    daemon(
        AGENT_CLI_HYBRID,
        "Declared by the phone's terminal in `set-client-info` (the lean stream): an agent CLI's terminal as `agent-cli-frame` cell deltas.",
        // Like `cloud-mobile-chat-v1`, the phone lists it in `set-client-info`.
        &["control:set-client-info.capabilities/agent-cli-hybrid-v1"],
    ),
    daemon(
        AGENT_CLI_HYBRID_LEAN,
        "With `agent-cli-hybrid-v1`: the same deltas packed as `agent-cli-lean`.",
        // Like `cloud-mobile-chat-v1`, the phone lists it in `set-client-info`.
        &["control:set-client-info.capabilities/agent-cli-hybrid-v2"],
    ),
    daemon(
        TERMINAL_SHELL_LINES,
        "With the hybrid pair: a plain shell's terminal as lean frames too, PTY bytes while it runs a full-screen program.",
        // Like `cloud-mobile-chat-v1`, the phone lists it in `set-client-info`.
        &["control:set-client-info.capabilities/terminal-shell-lines-v1"],
    ),
    daemon(
        ATTACH_OUTPUT_COALESCE,
        "`output` at most once per display frame for a terminal that stays on PTY bytes (#43373).",
        // Like `cloud-mobile-chat-v1`, the phone lists it in `set-client-info`.
        &["control:set-client-info.capabilities/attach-output-coalesce-v1"],
    ),
    daemon(
        TERMINAL_FULL_SCREEN_FRAMES,
        "With `terminal-shell-lines-v1`: a full-screen program as lean frames as well (its modes as bytes), one display frame apart, instead of its PTY repaints (#51565).",
        // Like `cloud-mobile-chat-v1`, the phone lists it in `set-client-info`.
        &["control:set-client-info.capabilities/terminal-full-screen-frames-v1"],
    ),
];

/// The capabilities table as PROTOCOL.md shows it between its markers.
pub fn capabilities_table() -> String {
    let mut out = String::from("| Name | Said by | Meaning |\n|---|---|---|\n");
    for capability in ALL {
        out.push_str(&format!(
            "| `{}` | {} | {} |\n",
            capability.name,
            capability.side.label(),
            capability.meaning
        ));
    }
    out
}

#[cfg(test)]
mod tests {
    use std::collections::HashSet;
    use std::path::PathBuf;

    use super::*;

    const BEGIN: &str = "<!-- link-names:capabilities:begin (printed from cmux-mobile-link src/names.rs; CMUX_UPDATE_LINK_NAMES=1 cargo test -p cmux-mobile-link names rewrites it) -->\n";
    const END: &str = "<!-- link-names:capabilities:end -->";

    fn protocol_path() -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../PROTOCOL.md")
    }

    /// PROTOCOL.md's table is the one [`ALL`] prints. `CMUX_UPDATE_LINK_NAMES=1` rewrites it.
    #[test]
    fn protocol_table_is_current() {
        let path = protocol_path();
        let doc = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
        let start =
            doc.find(BEGIN).unwrap_or_else(|| panic!("{} has no begin marker", path.display())) + BEGIN.len();
        let end =
            start + doc[start..].find(END).unwrap_or_else(|| panic!("{} has no end marker", path.display()));
        let now = capabilities_table();
        if std::env::var("CMUX_UPDATE_LINK_NAMES").as_deref() == Ok("1") {
            std::fs::write(&path, format!("{}{now}{}", &doc[..start], &doc[end..]))
                .expect("write PROTOCOL.md");
            return;
        }
        assert!(
            doc[start..end] == now,
            "{} capability table is stale: rerun `CMUX_UPDATE_LINK_NAMES=1 cargo test -p cmux-mobile-link names` and commit it",
            path.display()
        );
    }

    /// The lean stream declares full-screen frames with the shell lines it needs, and every
    /// name it declares is in [`ALL`].
    #[test]
    fn the_lean_stream_declares_full_screen_frames_with_the_shell_lines() {
        for name in TERMINAL_LEAN_STREAM {
            assert!(ALL.iter().any(|capability| capability.name == *name), "{name} is not in ALL");
        }
        for name in
            [AGENT_CLI_HYBRID, AGENT_CLI_HYBRID_LEAN, TERMINAL_SHELL_LINES, TERMINAL_FULL_SCREEN_FRAMES]
        {
            assert!(TERMINAL_LEAN_STREAM.contains(&name), "{name}");
        }
    }

    #[test]
    fn every_name_is_unique_and_versioned() {
        let mut seen = HashSet::new();
        for capability in ALL {
            assert!(seen.insert(capability.name), "{} is listed twice", capability.name);
            let (stem, version) = capability.name.rsplit_once("-v").expect("a -vN suffix");
            assert!(
                !stem.is_empty()
                    && stem.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
            );
            assert!(version.parse::<u32>().is_ok(), "{}", capability.name);
            assert!(!capability.meaning.contains('|') && !capability.meaning.contains('\n'));
        }
    }

    #[test]
    fn host_service_registry_round_trips() {
        let mut seen = HashSet::new();
        for service in HostService::ALL {
            assert!(seen.insert(service.as_str()), "{} is listed twice", service.as_str());
            assert_eq!(HostService::parse(service.as_str()), Some(*service));
        }
        assert!(HostService::parse("_link.park").is_none());
        assert!(HostService::parse("unknown").is_none());
    }
}
