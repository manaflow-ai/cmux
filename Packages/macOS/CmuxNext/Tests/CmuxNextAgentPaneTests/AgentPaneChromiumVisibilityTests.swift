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

    /// A spare adopted for an existing chat waits outside the window until it drew the chat
    /// (`AgentPaneView.adoptSession`), under the pane's paint hold. Hidden by that hold's alpha, its
    /// Chromium page was throttled and drew the chat only at the hold's 500 ms limit: the adopted open
    /// came out slower than a cold one (HQ#5914). In place, the hold still hides it (#28002).
    @Test func anAdoptedPageHeldAwayKeepsDrawingUnderAPaintHold() async throws {
        let (view, chromium, window) = try await pane()
        defer { view.page?.close(); window.close() }
        view.loadingView.leave(over: view.pageContent, fades: false)
        let size = NSRect(x: 0, y: 0, width: 800, height: 600)
        let host = NSView(frame: size)
        let outgoing = NSView(frame: size)
        let incoming = GatedHost(frame: size)
        window.setContentSize(size.size)
        window.contentView = host
        host.addSubview(outgoing)
        host.addSubview(incoming)
        view.frame = size
        incoming.addSubview(view)
        view.pageContent.frame = AgentPaneView.awayFrame(of: size)
        let hold = PanePaintHold(owner: "test.window.adopted-away")
        hold.begin(outgoing: outgoing, incoming: incoming, in: host, release: { $0.removeFromSuperview() })
        #expect(chromium.visibility.last == true, "an adopted page held outside the window was hidden by the paint hold and drew late")
        view.pageContent.frame = size
        PageWebView.syncChromiumVisibility(in: view)
        #expect(chromium.visibility.last == false, "a page in place under a paint hold must stay hidden (#28002)")
        hold.end()
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

    /// A page view tells a new Chromium page whether it shows in the same run that makes the page its own. Until it
    /// tells, the page counts as not shown, and the lookup of the pane under a page window answers no view for it.
    /// The row reads the page view at each turn of the main actor from the start, and at the first turn that has the
    /// Chromium page it wants the tell made, with the value that a tell gives then.
    @Test func aNewChromiumPageIsToldWhetherItShowsInTheRunThatStartsIt() async throws {
        _ = NSApplication.shared
        let file = try #require(AgentPageTestRoot.page)
        let hosting = FakeChromiumHosting()
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), source: .bundled(file),
                                              pageHost: true, chromium: hosting))
        let page = try #require(view.page)
        let window = NSWindow(contentRect: view.bounds, styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { page.close(); window.close() }
        try #require(!page.showsChromium, "setup: the page view has its Chromium page before the first turn after its start")
        var turns = 0
        let limit = ContinuousClock.now + .seconds(5)
        while !page.showsChromium, ContinuousClock.now < limit {
            await Task.yield()
            turns += 1
        }
        try #require(page.showsChromium, "setup: the page view has no Chromium page after \(turns) turns and 5 s")
        let chromium = try #require(hosting.made.first)
        let told = chromium.visibility, shows = page.chromiumShows
        page.setChromiumVisibility(true)
        print("AgentPaneChromiumVisibilityTests: the first turn that has the Chromium page (turn \(turns)): the page view told it \(told); "
            + "a tell at that turn gives \(page.chromiumShows)")
        #expect(!told.isEmpty, "the page view has a new Chromium page and did not tell it whether it shows")
        #expect(shows == page.chromiumShows, "the page view told its new Chromium page \(shows); a tell at that turn gives \(page.chromiumShows)")
    }
}
