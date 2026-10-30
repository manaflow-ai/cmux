import AppKit
import CmuxNextPagesTestSupport
import Testing
@testable import CmuxNextAgentPane
@testable import CmuxNextPages

/// Chromium follows every alpha hold, including holds outside a pane container.
@Suite(.serialized)
@MainActor
struct AgentPaneChromiumVisibilityTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    private final class GatedHost: NSView, PaneFirstPaintGated {
        var awaitsFirstPaint: Bool { true }
        func whenFirstPainted(_ body: @escaping () -> Void) {}
    }

    private func pane() async throws -> (AgentPaneView, FakeChromiumPage, NSWindow) {
        _ = NSApplication.shared
        let file = try #require(AgentPageTestRoot.page)
        let hosting = FakeChromiumHosting()
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), source: .bundled(file),
                                              pageHost: true, chromium: hosting))
        let page = try #require(view.page)
        await page.chromiumStart?.value
        let chromium = try #require(hosting.made.first)
        let window = NSWindow(contentRect: view.bounds, styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        return (view, chromium, window)
    }

    /// The launch image stays until the chat paints: the document's first frame is an empty chat.
    @Test func pagePaintedWaitsForTheChatNotTheDocument() async throws {
        let (view, _, window) = try await pane()
        defer { view.page?.close(); window.close() }
        var ran = false
        view.whenPagePainted { ran = true }
        view.page?.notePainted()
        #expect(!ran, "the document's first frame cleared the launch image before the chat painted")
        view.model.markPainted()
        #expect(ran)
    }

    @Test func aWindowHoldHidesAndRevealsNestedChromium() async throws {
        let (view, chromium, window) = try await pane()
        defer { view.page?.close(); window.close() }
        view.loadingView.leave(over: view.pageContent, fades: false)
        let host = NSView()
        let outgoing = NSView()
        let incoming = GatedHost()
        window.contentView = host
        host.addSubview(outgoing)
        host.addSubview(incoming)
        incoming.addSubview(view)
        #expect(chromium.visibility.last == true)
        let hold = PanePaintHold(owner: "test.window.chromium-hold")
        hold.begin(outgoing: outgoing, incoming: incoming, in: host, release: { $0.removeFromSuperview() })
        #expect(chromium.visibility.last == false)
        hold.end()
        #expect(chromium.visibility.last == true)
        #expect(outgoing.superview == nil)
    }

    @Test func loadingWithoutAFadeRevealsChromium() async throws {
        let (view, chromium, window) = try await pane()
        defer { view.page?.close(); window.close() }
        view.loadingView.leave(over: view.pageContent, fades: false)
        view.beginLoadingState()
        #expect(chromium.visibility.last == false)
        view.loadingView.leave(over: view.pageContent, fades: false)
        #expect(view.pageContent.alphaValue == 1)
        #expect(chromium.visibility.last == true)
    }

    @Test func aMoveCoverRevealsChromium() async throws {
        let (view, chromium, window) = try await pane()
        defer { view.page?.close(); window.close() }
        view.loadingView.leave(over: view.pageContent, fades: false)
        view.model.markPainted()
        view.hideMovedPage(until: {})
        #expect(chromium.visibility.last == false)
        view.revealMovedPage()
        #expect(view.pageContent.alphaValue == 1)
        #expect(chromium.visibility.last == true)
    }

    @Test func handingOffAHoldKeepsWithdrawnChromiumHidden() async throws {
        let (view, chromium, window) = try await pane()
        defer { view.page?.close(); window.close() }
        view.loadingView.leave(over: view.pageContent, fades: false)
        let host = NSView()
        let outgoing = NSView()
        let incoming = GatedHost()
        window.contentView = host
        host.addSubview(outgoing)
        host.addSubview(incoming)
        incoming.addSubview(view)
        let hold = PanePaintHold(owner: "test.window.chromium-handoff")
        hold.begin(outgoing: outgoing, incoming: incoming, in: host, release: { $0.removeFromSuperview() })
        hold.handOff { $0.removeFromSuperview() }
        #expect(incoming.alphaValue == 1)
        #expect(chromium.visibility.last == false)
        host.addSubview(incoming)
        #expect(chromium.visibility.last == true)
    }
}
