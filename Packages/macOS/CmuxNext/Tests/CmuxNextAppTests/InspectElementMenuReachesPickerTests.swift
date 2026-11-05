import AppKit
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// "this inspect element button doesn't work" and "but this literally is an agent tab" (Leo,
/// 2026-11-05): the agent chat's Inspect Element row posts `.cmuxNextInspectUIElement`, and only
/// ``UIInspectorController`` listens, from its init. Built lazily, it existed only after the
/// palette or a key had run the toggle, so in a fresh launch the row reached nothing.
@MainActor @Suite(.serialized, .closesItsWindows) struct InspectElementMenuReachesPickerTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    @Test func theAgentTabMenuRowStartsThePickerRightAfterLaunch() async throws {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register([AgentPaneTunables.pointerInspector.descriptor])
        TunableStore.shared.set(AgentPaneTunables.pointerInspector.key, .bool(true))
        defer { TunableStore.shared.set(AgentPaneTunables.pointerInspector.key, nil) }
        let services = AppServices(environment: AppEnvironment.current([:]))
        let chat = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), source: .bundled(URL(filePath: "/dev/null"))))
        services.agentTabs.views["tab_inspect"] = chat
        defer { services.agentTabs.views["tab_inspect"] = nil }
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        chat.frame = window.contentView?.bounds ?? .zero
        window.contentView?.addSubview(chat)
        window.orderFront(nil)

        // The person's choice of the row in the agent tab's own right-click menu.
        let ran = chat.debugRunMenuItem(title: "Inspect Element", pane: "tab_inspect")
        #expect(ran["ran"]?.boolValue == true, "\(ran)")
        let deadline = ContinuousClock.now + .seconds(2)
        while !services.uiInspector.isPicking, ContinuousClock.now < deadline { await Task.yield() }
        defer { if services.uiInspector.isPicking { services.uiInspector.toggle() } }

        #expect(services.uiInspector.isPicking, "Inspect Element in the agent tab's menu reached no picker")
        // While picking, a click over the agent tab picks its element instead of reaching the page.
        let centre = window.convertPoint(toScreen: chat.convert(NSPoint(x: chat.bounds.midX, y: chat.bounds.midY), to: nil))
        let click = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: window.convertPoint(fromScreen: centre), modifierFlags: [],
                                                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        #expect(services.uiInspector.handle(click, window: window, point: centre) == nil, "a click over the agent tab went past the picker")
    }
}
