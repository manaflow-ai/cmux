import AppKit
import CmuxNextPagesTestSupport
import CmuxNextTestSupport
import Testing
@testable import CmuxNextAgentPane
@testable import CmuxNextPages

/// Chromium follows every alpha hold, including holds outside a pane container.
@Suite(.serialized, .closesItsWindows)
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

    /// The loading state waits for the page's first frame: Chromium must keep drawing under it.
    @Test func loadingKeepsChromiumDrawingAndRevealsIt() async throws {
        let (view, chromium, window) = try await pane()
        defer { view.page?.close(); window.close() }
        view.loadingView.leave(over: view.pageContent, fades: false)
        view.beginLoadingState()
        #expect(view.pageContent.alphaValue == 0)
        #expect(chromium.visibility.last == true, "a hidden Chromium page never paints, so the loading state never left")
        view.loadingView.leave(over: view.pageContent, fades: false)
        #expect(view.pageContent.alphaValue == 1)
        #expect(chromium.visibility.last == true)
    }

    /// A move cover waits for the page's next frame: Chromium must keep drawing under it.
    @Test func aMoveCoverKeepsChromiumDrawing() async throws {
        let (view, chromium, window) = try await pane()
        defer { view.page?.close(); window.close() }
        view.loadingView.leave(over: view.pageContent, fades: false)
        view.model.markPainted()
        view.hideMovedPage(until: {})
        #expect(chromium.visibility.last == true)
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

    /// A prewarmed spare parked off screen must paint before it is adopted. Hidden by its parking's alpha, a
    /// Chromium spare never painted, and every Cmd-T waited for the pane hold's 500 ms limit (Leo 2026-10-30:
    /// "MAN WE FUCKINGKNOW WHAT THE NEW TAB PAGE LOOKS LIKE HOW CAN IT BE FUCKING SDLOW").
    @Test func anOffscreenParkingKeepsAParkedSpareDrawing() async throws {
        let (view, chromium, window) = try await pane()
        defer { view.page?.close(); window.close() }
        view.loadingView.leave(over: view.pageContent, fades: false)
        let host = NSView()
        let parking = PageOffscreenParking() // the New Tab spare's parking: alpha 0, off screen
        window.contentView = host
        host.addSubview(parking)
        parking.addSubview(view)
        PageWebView.syncChromiumVisibility(in: view)
        #expect(chromium.visibility.last == true, "a parked Chromium spare hidden by its parking's alpha never paints")
        // Any other transparent ancestor (a paint hold) still hides it (#28002).
        parking.alphaValue = 1
        host.alphaValue = 0
        PageWebView.syncChromiumVisibility(in: view)
        #expect(chromium.visibility.last == false)
    }
}
