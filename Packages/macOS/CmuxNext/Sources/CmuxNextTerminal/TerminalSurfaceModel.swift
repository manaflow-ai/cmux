public import AppKit
import CmuxNextCompat
public import Observation
public import CmuxNextTerminalGeometry

/// Terminal grid in cells (defined with the pure geometry policy).
public typealias TerminalGridSize = CmuxNextTerminalGeometry.TerminalGridSize

/// Observable state of one terminal session, fed by Ghostty actions. The
/// tab strip, sidebar, and notification UI read this; nothing here writes
/// back to Ghostty.
@Observable
public final class TerminalSurfaceModel {
    /// OSC 0/2 title. Empty until the program sets one.
    public internal(set) var title: String = ""
    /// OSC 7 working directory, as reported (a path or `file://` URL).
    public internal(set) var workingDirectory: String?
    /// Increments on every BEL. Observers diff it to flash a tab.
    public internal(set) var bellCount: Int = 0
    /// URL under the pointer while hovering a link.
    public internal(set) var hoveredLink: String?
    public internal(set) var progress: TerminalProgress?
    public internal(set) var lastCommand: TerminalCommandResult?
    public internal(set) var scrollbar: TerminalScrollbar?
    /// Grid the surface currently renders.
    public internal(set) var grid: TerminalGridSize?
    /// Cell size in backing pixels.
    public internal(set) var cellPixelSize: CGSize = .zero
    /// First responder in the key window.
    public internal(set) var isFocused = false
    /// True after the terminal's process exited.
    public internal(set) var hasExited = false
    /// The view's link to its terminal (a daemon IO reports it).
    public internal(set) var connection: TerminalConnectionStatus = .connected
    public internal(set) var isRendererHealthy = true
    public internal(set) var isReadOnly = false
    /// A multi-key Ghostty binding is waiting for its next key.
    public internal(set) var isKeySequencePending = false
    /// Background set by OSC 11, nil when the config background applies.
    public internal(set) var backgroundOverride: NSColor?

    public init() {}

    // cx-qxxu: Cmd-T's New Tab page withdraws a terminal while its action runs; the default
    // main-actor deinit's hop traps there (cx-t7hu). Teardown only releases values.
    nonisolated deinit {}
}

/// Hooks the App implements to act on terminal requests. Every method has a
/// default, so a demo host can leave the delegate nil.
public protocol TerminalSessionDelegate: AnyObject {
    /// A Ghostty keybind asked for a window, tab, or split change. Return
    /// true when handled; false lets Ghostty treat the key as unbound.
    func terminalSession(_ session: TerminalSession, perform action: TerminalHostAction) -> Bool
    /// A link was activated (cmd-click or `open_url`). Return true when handled.
    func terminalSession(_ session: TerminalSession, open url: URL) -> Bool
    /// A link was activated with Ghostty's text for it: a URL, or a path as printed (trailing
    /// punctuation, `:line:col`, relative to the shell's directory). The default makes a URL of it
    /// (``terminalSession(_:open:)``).
    func terminalSession(_ session: TerminalSession, openLink text: String) -> Bool
    /// The check that decides which detected links under a Cmd-hover are links
    /// (``TerminalSession/linkCheck``), read when the delegate is set. Nil: all of them.
    func terminalSessionLinkCheck(_ session: TerminalSession) -> TerminalLinkCheck?
    /// BEL with the `system` bell feature enabled.
    func terminalSessionDidRingBell(_ session: TerminalSession)
    /// Ghostty asked to close the surface (for example `close_surface`).
    func terminalSessionDidRequestClose(_ session: TerminalSession)
    /// Right-click menu for the terminal. Nil shows the built-in
    /// Copy/Paste/Select All menu.
    func terminalSession(_ session: TerminalSession, contextMenuFor event: NSEvent) -> NSMenu?
}

public extension TerminalSessionDelegate {
    func terminalSession(_ session: TerminalSession, perform action: TerminalHostAction) -> Bool { false }
    func terminalSession(_ session: TerminalSession, contextMenuFor event: NSEvent) -> NSMenu? { nil }
    func terminalSession(_ session: TerminalSession, open url: URL) -> Bool {
        guard let safeURL = TerminalSurfaceView.url(from: url.absoluteString) else { return false }
        if safeURL.isFileURL {
            NSWorkspace.shared.revealInBackground([safeURL])
            return true
        }
        NSWorkspace.shared.open(safeURL, configuration: NSWorkspace.OpenConfiguration())
        return true
    }
    func terminalSession(_ session: TerminalSession, openLink text: String) -> Bool {
        guard let url = TerminalSurfaceView.url(from: text) else { return false }
        return terminalSession(session, open: url)
    }
    func terminalSessionLinkCheck(_ session: TerminalSession) -> TerminalLinkCheck? { nil }
    /// Ghostty's `bell-features` decide (no system beep by default).
    func terminalSessionDidRingBell(_ session: TerminalSession) {
        GhosttyRuntime.shared.bellSettings.ring()
    }
    func terminalSessionDidRequestClose(_ session: TerminalSession) {}
}
