#if DEBUG
public import AppKit

/// DEBUG ONLY: Debug > MCP Connect Card Playground (user 2026-11-03: "connect to a MCP server …
/// have it open a card/button"; design playgrounds are Swift, user 2026-11-02). One window with
/// every card style for every kind of server, in every phase, light and dark side by side. The
/// labels are DEV-only English.
@MainActor
public final class McpConnectCardPlayground: NSObject, NSWindowDelegate {
    static let identifier = NSUserInterfaceItemIdentifier("cmux.home.mcpConnectPlayground")

    private let window: NSWindow
    private let model = McpConnectPlaygroundModel()

    /// Shows the playground (one window), switched to the given style (1...6), server (0...5) and
    /// phase (0...6); nil keeps what it shows.
    public static func show(style: Int? = nil, fixture: Int? = nil, phase: Int? = nil) {
        let shown = NSApp.windows.first { $0.identifier == identifier }
        let playground = (shown?.contentView as? McpConnectPlaygroundContainer)?.owner as? McpConnectCardPlayground
            ?? McpConnectCardPlayground()
        playground.model.select(style: style.flatMap(McpConnectCardStyle.init(rawValue:)),
                                fixture: fixture.flatMap(McpConnectCardFixture.init(rawValue:)),
                                phase: phase.flatMap(McpConnectPlaygroundPhase.init(rawValue:)))
        playground.window.makeKeyAndOrderFront(nil)
    }

    private override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 560),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.identifier = Self.identifier
        window.title = "MCP Connect Card Playground"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let container = McpConnectPlaygroundContainer()
        container.owner = self
        let page = McpConnectPlaygroundView(model: model)
        page.autoresizingMask = [.width, .height]
        container.addSubview(page)
        window.contentView = container
        page.frame = container.bounds
        window.center()
    }
}
#endif
