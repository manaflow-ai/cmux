public import AppKit
import CmuxNextDesign

/// Development window: one terminal surface on a local shell PTY, with a
/// live hover-preview mirror in the corner. Lets the terminal module be
/// exercised before the daemon client exists. Not reachable in release UI.
public enum TerminalDebugWindow {
    private static var controllers: [NSWindowController] = []

    /// Opens the local-shell window. `initialInput` is sent through the
    /// surface (so it exercises io_write_cb -> TerminalIO.write -> PTY).
    @discardableResult
    public static func showLocalShell(initialInput: String? = nil) -> NSWindowController? {
        let io: LocalPTYTerminalIO
        do {
            io = try LocalPTYTerminalIO()
        } catch {
            GhosttyRuntime.logger.error("local PTY spawn failed: \(String(describing: error), privacy: .public)")
            return nil
        }
        let session = TerminalSession(io: io)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "terminal.debug.window.title", defaultValue: "Local Terminal (Debug)", bundle: .module)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed

        let container = DebugContainerView(session: session)
        window.contentView = container

        let controller = DebugWindowController(window: window, session: session, io: io)
        controllers.append(controller)
        WindowPlacement.present(window)
        session.focus()
        if let initialInput { session.sendText(initialInput) }
        return controller
    }

    /// Opens a window fed by a ``ScriptedTerminalIO`` that exercises the
    /// daemon-shaped paths: replay, live output, a second replay (surface
    /// swap), and a canonical grid the view does not own.
    @discardableResult
    public static func showScriptedFollower() -> NSWindowController? {
        let io = ScriptedTerminalIO()
        let session = TerminalSession(io: io, ownsGeometry: false)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 420),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "terminal.debug.follower.title", defaultValue: "Scripted Follower (Debug)", bundle: .module)
        window.isReleasedWhenClosed = false
        window.contentView = session.view
        let controller = DebugWindowController(window: window, session: session, io: nil)
        controllers.append(controller)
        WindowPlacement.present(window)

        let esc = "\u{1B}"
        io.send(.replay(Data("\(esc)c\(esc)[3Jfirst replay (must disappear)\r\n".utf8)))
        io.send(.output(Data("output into the first surface\r\n".utf8)))
        io.send(.replay(Data("\(esc)c\(esc)[1;32msecond replay\(esc)[0m in a fresh surface\r\n".utf8)))
        io.send(.resize(cols: 60, rows: 12))
        // Wraps at column 60 only if the canonical grid applied.
        let ruler = (1...8).map { String(repeating: String($0), count: 9) + "|" }.joined()
        io.send(.output(Data("live output after the swap, grid 60x12:\r\n\(ruler)\r\n".utf8)))
        return controller
    }

    fileprivate static func remove(_ controller: NSWindowController) {
        controllers.removeAll { $0 === controller }
    }
}

private final class DebugWindowController: NSWindowController, NSWindowDelegate {
    private let session: TerminalSession
    private let io: LocalPTYTerminalIO?

    init(window: NSWindow, session: TerminalSession, io: LocalPTYTerminalIO?) {
        self.session = session
        self.io = io
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func windowWillClose(_ notification: Notification) {
        session.close()
        io?.terminate()
        TerminalDebugWindow.remove(self)
    }
}

/// Terminal filling the window plus a small mirror pinned bottom-right.
private final class DebugContainerView: NSView {
    private let terminal: NSView
    private let mirror: TerminalMirrorView

    init(session: TerminalSession) {
        terminal = session.view
        mirror = session.makeMirrorView()
        super.init(frame: .zero)
        addSubview(terminal)
        mirror.wantsLayer = true
        mirror.layer?.cornerRadius = 8
        mirror.layer?.borderWidth = 1
        mirror.layer?.borderColor = NSColor(white: 0.5, alpha: 0.4).cgColor
        addSubview(mirror)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        terminal.frame = bounds
        let size = NSSize(width: 240, height: 150)
        mirror.frame = NSRect(x: bounds.maxX - size.width - 12, y: 12, width: size.width, height: size.height)
    }
}
