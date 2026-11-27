#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
@testable import CmuxNextPages
import CmuxNextPagesTestSupport
import Testing
import CmuxNextTestSupport

/// A capture sends Return directly to Chromium's non-key child window. Its owning pane must
/// see the same event as its local monitor would, or a native /btw request has no gesture.
@MainActor @Suite(.closesItsWindows, .serialized)
struct DebugChromiumGestureTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    @Test func aDirectChromiumReturnReachesItsOwningPanesGestureMonitor() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let folder = FileManager.default.temporaryDirectory.appending(path: "debug-chromium-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "index.html")
        try Data("<html><body><textarea></textarea></body></html>".utf8).write(to: file)
        let hosting = FakeChromiumHosting()
        let pane = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), source: .bundled(file),
                                              pageHost: true, testRoot: true, chromium: hosting))
        let frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let parent = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        let child = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        child.isReleasedWhenClosed = false
        parent.contentView = pane
        pane.frame = frame
        services.agentTabs.views["debug-chromium-gesture"] = pane
        defer {
            services.agentTabs.views["debug-chromium-gesture"] = nil
            pane.close()
            child.close()
            parent.close()
        }
        let start = try #require(pane.page?.chromiumStart)
        await start.value
        let chromium = try #require(pane.chromiumPage?.contentView)
        parent.addChildWindow(child, ordered: .above)
        chromium.removeFromSuperview()
        child.contentView = chromium
        chromium.frame = frame
        try #require(!child.isKeyWindow)
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                  timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: child.windowNumber, context: nil, characters: "\r",
                                                  charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        try #require(event.window === child)
        let source = try #require(event.cgEvent)
        source.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
        DebugNativeInput.runPaneMonitors(event, in: child, services: services)
        #expect(pane.model.transport.gestures.consume(), "the parent pane missed Chromium's Return")
        #expect(!pane.model.transport.gestures.consume(), "one Return grants exactly one request")
    }
}
#endif
