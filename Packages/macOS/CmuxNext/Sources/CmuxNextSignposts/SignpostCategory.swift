/// The fixed signpost categories of the cmux app (subsystem ``SignpostCategory/subsystem``).
///
/// A category groups the intervals of one kind of user-visible work, so a bench or an
/// Instruments session can record one path (`log stream --signpost --predicate 'category ==
/// "action"'`). The raw values are stable: benches, Instruments templates and PL-telemetry's
/// opt-in hang reports match on them.
public nonisolated enum SignpostCategory: String, Sendable, CaseIterable {
    /// Keyboard, menu, palette, context-menu and CLI actions (`ActionRegistry`).
    case action
    /// Layout motion: spring frames, live resize.
    case motion
    /// A key press to the frame that shows it (terminal, Home composer, omnibar).
    case key
    /// Workspace, tab, space and window switches.
    case `switch`
    /// Creating a workspace, pane or tab (terminal, Chromium, WebKit, chat, page).
    case create
    /// Chromium work on the main thread: message pump passes, browser window creation.
    case cef
    /// Launch phases.
    case launch
    /// Main-thread spans the stall bench measures (palette open, surface creation).
    case stall
    /// Burst bench events (`BurstSignposts` in CmuxNextControl, scripts/cmux-next/burst-bench.py): a
    /// refusal the person saw, a grid sent to a PTY, that terminal's first output after it. Events,
    /// not intervals; the bench times each against the press before it.
    case burst

    /// The unified-log subsystem every cmux signpost uses.
    public static let subsystem = "com.cmuxterm.app.next"
}
