public import AppKit
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
    public internal(set) var search: TerminalSearchState?
    /// Grid the surface currently renders.
    public internal(set) var grid: TerminalGridSize?
    /// Cell size in backing pixels.
    public internal(set) var cellPixelSize: CGSize = .zero
    /// First responder in the key window.
    public internal(set) var isFocused = false
    /// True after the terminal's process exited.
    public internal(set) var hasExited = false
    public internal(set) var isRendererHealthy = true
    public internal(set) var isReadOnly = false
    /// A multi-key Ghostty binding is waiting for its next key.
    public internal(set) var isKeySequencePending = false
    /// Background set by OSC 11, nil when the config background applies.
    public internal(set) var backgroundOverride: NSColor?

    public init() {}
}

/// Hooks the App implements to act on terminal requests. Every method has a
/// default, so a demo host can leave the delegate nil.
public protocol TerminalSessionDelegate: AnyObject {
    /// A Ghostty keybind asked for a window, tab, or split change. Return
    /// true when handled; false lets Ghostty treat the key as unbound.
    func terminalSession(_ session: TerminalSession, perform action: TerminalHostAction) -> Bool
    /// OSC 9 / OSC 777 desktop notification.
    func terminalSession(_ session: TerminalSession, didPostNotification title: String, body: String)
    /// A link was activated (cmd-click or `open_url`). Return true when handled.
    func terminalSession(_ session: TerminalSession, open url: URL) -> Bool
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
    func terminalSession(_ session: TerminalSession, didPostNotification title: String, body: String) {}
    func terminalSession(_ session: TerminalSession, open url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }
    func terminalSessionDidRingBell(_ session: TerminalSession) {
        NSSound.beep()
    }
    func terminalSessionDidRequestClose(_ session: TerminalSession) {}
}
