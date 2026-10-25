/// Whether a script cmux runs in a page acts as the person (`evaluate(_:world:gesture:)`). Every
/// call states it, with no default, so a new probe cannot hand a page the person's activation by
/// accident.
///
/// A script with a user gesture gives the page transient and sticky activation
/// (`navigator.userActivation`): it may then open a popup, start sound, enter fullscreen, or ask
/// before it unloads, as after the person's click. cmux's own probes ran with one in both engines,
/// so every hidden page it probed could do those things without the person.
public nonisolated enum BrowserScriptGesture: Hashable, Sendable {
    /// Acts as the user: an agent's call (`cmux browser`, MCP, the REPL; its click on a
    /// target=_blank link opens the tab) or the person's own command (Play on the media card,
    /// a Developer Tools command).
    case agent
    /// cmux's own work (probes, recorders, reads, link hint drawing): no gesture. Where the engine
    /// cannot run a page-world script without one (WebKit without its gesture-free evaluation), the
    /// call throws `BrowserTabError.unsupported` instead of running with a gesture.
    case cmux
}
