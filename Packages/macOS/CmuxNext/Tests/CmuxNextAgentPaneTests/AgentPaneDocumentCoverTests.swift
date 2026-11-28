#if DEBUG
import AppKit
@testable import CmuxNextPages
import CmuxNextPagesTestSupport
import CmuxNextTestSupport
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Leo, 2026-11-22 06:44Z: "also holy fuck idk why there was some sort of situation just now that compLETELY
/// blanked out this agent chat + the update notes"; 06:47Z: "i just saw the entire thing flash and then re-render
/// and then shift as it loaded in". A chat that drew keeps its last frame on screen through every later document,
/// whatever replaced it (a host reload, app health's reload or renderer restart, a web content process that
/// ended), until the new document reports its first paint; never the empty new document over the wallpaper.
@Suite(.serialized, .closesItsWindows)
@MainActor
struct AgentPaneDocumentCoverTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// What one sampled frame of the pane shows.
    enum Shown: Equatable { case picture, loading, page, blank }

    private static func pane(chromium: Bool = false, source: URL? = nil) async throws -> (AgentPaneView, NSWindow) {
        _ = NSApplication.shared
        let file = try #require(source ?? AgentPageTestRoot.page)
        let terminations = AgentPageTerminations()
        terminations.afterTurn = { _ in }
        terminations.writeMarker = { _, _, _ in }
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost(), sessionId: "s-reload"), source: .bundled(file),
                                              pageHost: true, testRoot: true, chromium: chromium ? FakeChromiumHosting() : nil,
                                              terminations: terminations))
        if chromium {
            let page = try #require(view.page)
            await page.chromiumStart?.value
            #expect(view.pageDrawsOverCovers)
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 360), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        view.frame = NSRect(x: 0, y: 0, width: 480, height: 360)
        window.contentView = view
        window.orderFrontRegardless()
        view.layoutSubtreeIfNeeded()
        view.crashRetry.nobodySees = { _ in false }
        return (view, window)
    }

    /// The page's paint report, as the chat page sends it once it drew what it is.
    private static func paintReport(_ view: AgentPaneView) async {
        _ = await view.model.respond(to: AgentPaneRequest(body: ["method": "pane.painted"]))
    }

    /// An opaque picture of the page's size, standing in for its snapshot.
    private static func picture(of view: AgentPaneView) -> NSImage {
        let size = view.topBar.pageFrame(in: view.bounds).size
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.systemTeal.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        return image
    }

    private static func settle(_ bound: Duration = .seconds(30), until done: () -> Bool) async throws {
        let deadline = ContinuousClock.now + bound
        while !done(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    }

    /// What the pane shows now: its cover's picture, its cover's loading state, the page (shown and drawn), or
    /// nothing (an unpainted or hidden page with no cover over it).
    /// `withoutCover`: what the pane would show with no reload cover (the build before it), the before of the
    /// same frames.
    static func shown(_ view: AgentPaneView, withoutCover: Bool = false) -> Shown {
        let cover = view.documentCover
        if !withoutCover, cover.isShown, cover.view.superview === view, !cover.view.isHidden {
            return cover.showsPicture && cover.view.layer?.contents != nil ? .picture : .loading
        }
        if view.loadingView.superview === view, !view.loadingView.isHidden { return .loading }
        // The cover's own hiding of the page does not count in the before.
        let hiddenByCover = withoutCover && cover.isShown
        let pageVisible = hiddenByCover || (view.pageContent.alphaValue > 0 && !view.holdsPageAway)
        guard pageVisible, view.model.hasPainted, let page = view.page else { return .blank }
        // A page whose document went (its renderer ended, a new one committed and has not painted) draws nothing.
        return page.loaded || page.hasPainted ? .page : .blank
    }

    /// Samples what the pane shows on every main-actor turn (about every 4 ms) until stopped.
    @MainActor final class Sampler {
        private(set) var frames: [Shown] = []
        /// The same frames as the pane before the cover would have shown them.
        private(set) var before: [Shown] = []
        private var task: Task<Void, Never>?

        func start(_ view: AgentPaneView) {
            task = Task { @MainActor [weak self, weak view] in
                while !Task.isCancelled, let view {
                    self?.frames.append(AgentPaneDocumentCoverTests.shown(view))
                    self?.before.append(AgentPaneDocumentCoverTests.shown(view, withoutCover: true))
                    try? await Task.sleep(for: .milliseconds(4))
                }
            }
        }

        func stop() -> [Shown] {
            task?.cancel()
            return frames
        }
    }

    /// A painted chat with its last frame remembered.
    private static func paintedWithPicture(chromium: Bool = false) async throws -> (AgentPaneView, NSWindow) {
        let (view, window) = try await pane(chromium: chromium)
        await paintReport(view)
        #expect(view.model.hasPainted)
        let image = picture(of: view)
        view.documentCover.takePicture = { _ in image }
        view.rememberLastFrame(fresh: true)
        try await settle { view.documentCover.frame != nil }
        #expect(view.documentCover.frame != nil, "the chat's last frame was not remembered")
        return (view, window)
    }

    /// The web content process ended (either engine): the last frame shows at once and stays through the retry's
    /// new document until that document's paint report, not the old document's late one.
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func anEndedPageKeepsItsLastFrameUntilItsNewDocumentPaints(chromium: Bool) async throws {
        let (view, window) = try await Self.paintedWithPicture(chromium: chromium)
        let page = try #require(view.page)
        defer { page.close(); window.close() }
        var retries: [@MainActor () -> Void] = []
        view.crashRetry.after = { _, body in retries.append(body) }

        page.lastTermination = PageTermination(reason: .crash)
        page.contentProcessTerminated()
        #expect(Self.shown(view) == .picture, "the pane showed \(Self.shown(view)) the moment its page ended")
        #expect(view.documentCover.cause == .contentEnded)
        #expect(!view.showsCrashNotice, "the first end showed the notice instead of a retry")
        if chromium { #expect(view.holdsPageAway, "Chromium's window would draw its empty page over the picture") }
        else { #expect(view.pageContent.alphaValue == 0) }

        // A report from the old document (in flight when it ended) reveals nothing.
        await Self.paintReport(view)
        #expect(Self.shown(view) == .picture, "the old document's report revealed the empty new one")

        retries.forEach { $0() }
        #expect(view.crashRetry.count == 1, "the ended page did not load again by itself")
        #expect(Self.shown(view) == .picture, "the retry's reload took the picture away")
        page.documentCommitted()
        #expect(Self.shown(view) == .picture, "the new document's commit showed it unpainted")

        await Self.paintReport(view)
        #expect(!view.documentCover.isShown, "the cover stayed after the new document painted")
        #expect(view.documentCover.view.superview == nil)
        #expect(!view.holdsPageAway)
        #expect(view.pageContent.alphaValue == 1)
        let recovery = try #require(view.documentCover.recoveries.last)
        #expect(recovery.cause == .contentEnded && recovery.picture)
        #expect(view.documentCover.rendererEnds == 1 && view.documentCover.blankReveals == 0)
        #expect(view.documentCover.covers[.contentEnded] == 1)
    }

    /// App health's reload, a web override's reload and the host's own: the old document draws until the commit,
    /// then the picture until the new document's report.
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func aHostReloadKeepsThePictureUntilTheNewDocumentPaints(chromium: Bool) async throws {
        let (view, window) = try await Self.paintedWithPicture(chromium: chromium)
        let page = try #require(view.page)
        defer { page.close(); window.close() }
        page.reload()
        #expect(Self.shown(view) == .picture)
        #expect(view.documentCover.cause == .reload)
        page.documentCommitted()
        #expect(Self.shown(view) == .picture)
        // The new document draws its first frame (the native probe), then its page reports it: the picture stays
        // until the report. (A commit with nothing drawn after it is a blank page, and `shown` says so.)
        page.notePainted()
        #expect(Self.shown(view) == .picture, "the new document's first frame revealed it before its report")
        await Self.paintReport(view)
        #expect(Self.shown(view) == .page)
        #expect(view.documentCover.recoveries.last?.cause == .reload)
    }

    /// Leo, 2026-11-22: "the agent pane just blanked out entirely yet again. i dont know what that was, some sort of
    /// ultra hard reload?" A render error the page's last boundary caught (webviews PaneBoundary.tsx) took the whole app
    /// down: the page drew nothing for the boundary's retry wait (a second, longer on each failure in a row), then
    /// `location.reload()`. The page says so at once (`pane.renderFailed`): the last frame shows from then, through the
    /// boundary's reload, until the reloaded document reports its paint. No picture is taken of the failed page.
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func aRenderFailureKeepsTheLastFrameThroughTheBoundarysReload(chromium: Bool) async throws {
        #expect(AgentPaneRequest(body: ["method": "pane.renderFailed"]) == .renderFailed)
        #expect(AgentPageOps.methods["pane.renderFailed"] == "pane.renderFailed", "the page host refuses the op")
        let (view, window) = try await Self.paintedWithPicture(chromium: chromium)
        let page = try #require(view.page)
        defer { page.close(); window.close() }
        _ = await view.model.respond(to: AgentPaneRequest(body: ["method": "pane.renderFailed"]))
        #expect(Self.shown(view) == .picture, "the pane showed \(Self.shown(view)) over the page its boundary emptied")
        #expect(view.documentCover.cause == .renderFailed)
        #expect(view.documentCover.covers[.renderFailed] == 1)
        if chromium { #expect(view.holdsPageAway, "Chromium's window would draw the empty page over the picture") }
        // The failed page is never remembered as the chat's last frame.
        view.rememberLastFrame(fresh: false)
        view.rememberLastFrame(fresh: true)
        #expect(!view.documentCover.capturing, "a picture of the failed page was started")
        // The boundary's own `location.reload()`: the new document commits, draws, then reports its paint.
        page.documentCommitted()
        #expect(Self.shown(view) == .picture)
        page.notePainted()
        #expect(Self.shown(view) == .picture, "the reloaded document's first frame revealed it before its report")
        await Self.paintReport(view)
        #expect(Self.shown(view) == .page)
        #expect(view.documentCover.recoveries.last?.cause == .renderFailed)
    }

    /// A page that fails on every load backs its retries off past the cover's limit (30 s at most): the cover goes then,
    /// and the page shows its own "Still loading the agent pane…" line instead of a stale picture for good.
    @Test(.timeLimit(.minutes(1)))
    func aRenderFailureWhoseReloadNeverComesEndsItsCover() async throws {
        let (view, window) = try await Self.paintedWithPicture()
        let page = try #require(view.page)
        defer { page.close(); window.close() }
        view.documentCover.uncommittedLimit = .milliseconds(50)
        _ = await view.model.respond(to: AgentPaneRequest(body: ["method": "pane.renderFailed"]))
        #expect(view.documentCover.cause == .renderFailed)
        try await Self.settle { !view.documentCover.isShown }
        #expect(!view.documentCover.isShown, "the render failure's cover stayed up with no reload coming")
        #expect(view.documentCover.uncommittedEnds == 1)
    }

    /// A new document nobody announced (a commit with no reload asked for, and no picture of this size): the
    /// loading state shows, never the unpainted page.
    @Test(.timeLimit(.minutes(1)))
    func aNewDocumentWithNoPictureShowsTheLoadingState() async throws {
        let (view, window) = try await Self.pane()
        let page = try #require(view.page)
        defer { page.close(); window.close() }
        await Self.paintReport(view)
        page.documentCommitted()
        #expect(Self.shown(view) == .loading, "the pane showed \(Self.shown(view)) over an unpainted document")
        #expect(!view.documentCover.showsPicture)
        page.notePainted() // the new document draws, then reports it
        #expect(Self.shown(view) == .loading, "the new document's first frame revealed it before its report")
        await Self.paintReport(view)
        #expect(Self.shown(view) == .page)
        let recovery = try #require(view.documentCover.recoveries.last)
        #expect(recovery.cause == .newDocument && !recovery.picture)
    }

    /// A reload whose new document never commits (a failed provisional load, a dropped Chromium navigation)
    /// takes its picture away after the limit: the old document still draws, and the stale picture stayed up
    /// for good before (review of cmux#51960).
    @Test(.timeLimit(.minutes(1)))
    func aReloadThatNeverCommitsEndsItsCover() async throws {
        let (view, window) = try await Self.paintedWithPicture()
        let page = try #require(view.page)
        defer { page.close(); window.close() }
        view.documentCover.uncommittedLimit = .milliseconds(50)
        view.documentWillChange(.reload)
        #expect(view.documentCover.isShown)
        try await Self.settle { !view.documentCover.isShown }
        #expect(Self.shown(view) == .page, "the old document stayed hidden after its reload never committed")
        #expect(view.documentCover.uncommittedEnds == 1)
        #expect(view.documentCover.recoveries.isEmpty, "an uncommitted reload counted as a recovery")
    }

    /// Clicks over the picture go to the page under it: the composer takes them before the new document painted.
    @Test(.timeLimit(.minutes(1)))
    func theCoverPassesClicksToThePage() async throws {
        let (view, window) = try await Self.paintedWithPicture()
        let page = try #require(view.page)
        defer { page.close(); window.close() }
        page.reload()
        #expect(view.documentCover.isShown)
        let center = NSPoint(x: view.bounds.midX, y: view.bounds.midY)
        #expect(view.documentCover.view.hitTest(view.documentCover.view.convert(center, from: view)) == nil, "the cover took a click meant for the page")
        // Keys: the cover never takes the keyboard; the page's view keeps first responder.
        #expect(!(window.firstResponder is AgentPaneLoadingView))
    }

    /// A page that keeps ending shows the crash notice over the page, not over a picture of a chat that works.
    @Test(.timeLimit(.minutes(1)))
    func theCrashNoticeTakesThePictureAway() async throws {
        let (view, window) = try await Self.paintedWithPicture()
        let page = try #require(view.page)
        defer { page.close(); window.close() }
        view.crashRetry.after = { _, _ in }
        for _ in 0...AgentPageCrashBudget.limit {
            page.lastTermination = PageTermination(reason: .crash)
            page.contentProcessTerminated()
        }
        #expect(view.showsCrashNotice)
        #expect(!view.documentCover.isShown, "the picture stayed under the crash notice")
        #expect(view.documentCover.recoveries.isEmpty, "an unpainted end counted as a recovery")
    }

    /// The loading state's give-up over a page host document that drew nothing keeps the loading state (it showed
    /// the empty document over the wallpaper: the "showing it" line of Leo's 06:44Z log); with no probe (the old
    /// host) or a document that drew, it shows the page as before.
    @Test func theGiveUpKeepsTheCoverOverADocumentThatDrewNothing() async throws {
        #expect(AgentPaneView.giveUpKeepsCover(documentDrew: false))
        #expect(!AgentPaneView.giveUpKeepsCover(documentDrew: true))
        #expect(!AgentPaneView.giveUpKeepsCover(documentDrew: nil))
        // A document that never loads (no file there) never draws.
        let (view, window) = try await Self.pane(source: URL(filePath: "/dev/null/none.html"))
        let page = try #require(view.page)
        defer { page.close(); window.close() }
        view.loadingView.paintCheckInterval = .milliseconds(40)
        try await Task.sleep(for: .milliseconds(600))
        #expect(view.loadingView.superview === view, "the give-up showed a document that drew nothing")
        #expect(!view.model.hasPainted)
        #expect(view.loadingView.awaitsGiveUp, "the give-up stopped checking")
        #expect(view.documentCover.blankReveals == 0)
    }

    /// The real thing on real WebKit: the page's web content process is killed (`_killWebContentProcess`, what app
    /// health's restart does), then the host reloads it. Every sampled frame shows the picture, the loading state or
    /// the drawn page, never nothing, and the new document loads within the bound. The numbers print as
    /// `reload-cover:` lines for the run's log.
    @Test(.timeLimit(.minutes(2)))
    func aKilledWebContentProcessNeverLeavesThePaneBlank() async throws {
        let (view, window) = try await Self.pane()
        let page = try #require(view.page)
        defer { page.close(); window.close() }
        view.crashRetry.after = { _, body in Task { @MainActor in body() } }
        try await Self.settle(.seconds(60)) { page.loaded }
        try #require(page.loaded, "the test page never loaded")
        await Self.paintReport(view)
        // The page's real picture; a host with no compositor gives none, and the loading state stands in.
        view.rememberLastFrame(fresh: true)
        try await Self.settle(.seconds(10)) { view.documentCover.frame != nil }
        let realPicture = view.documentCover.frame != nil

        for (round, cause) in [(1, "kill"), (2, "host-reload"), (3, "kill")] {
            let sampler = Sampler()
            sampler.start(view)
            let start = ContinuousClock.now
            if cause == "kill" {
                try #require(page.killWebContentProcess(), "this WebKit has no _killWebContentProcess")
                try await Self.settle { view.documentCover.isShown }
            } else {
                page.reload()
            }
            let covered = ContinuousClock.now - start
            // The test page has no chat bridge: the host plays its part, reporting once the new document loaded.
            try await Self.settle(.seconds(60)) { view.documentCover.documentsSince > 0 && page.loaded }
            let loaded = ContinuousClock.now - start
            await Self.paintReport(view)
            let frames = sampler.stop()
            let before = sampler.before.filter { $0 == .blank }.count
            let recovery = try #require(view.documentCover.recoveries.last, "round \(round): the cover never ended")
            print("reload-cover: round=\(round) cause=\(cause) engine=webkit cover_ms=\(covered.milliseconds) new_document_loaded_ms=\(loaded.milliseconds) first_paint_report_ms=\(recovery.milliseconds) picture=\(recovery.picture) real_picture=\(realPicture) frames=\(frames.count) blank_before=\(before) blank=\(frames.filter { $0 == .blank }.count) picture_frames=\(frames.filter { $0 == .picture }.count) loading_frames=\(frames.filter { $0 == .loading }.count)")
            #expect(!frames.contains(.blank), "round \(round) (\(cause)): \(frames.filter { $0 == .blank }.count) of \(frames.count) sampled frames showed nothing")
            #expect(recovery.milliseconds < 10_000, "round \(round) (\(cause)): the new document took \(recovery.milliseconds) ms to paint")
            #expect(Self.shown(view) == .page)
            if realPicture { #expect(recovery.picture, "round \(round): the remembered frame did not stand in") }
            // The next round's picture: the new document's frame.
            view.rememberLastFrame(fresh: true)
            try await Self.settle(.seconds(10)) { !view.documentCover.capturing }
        }
    }
}

private extension Duration {
    var milliseconds: Int { Int(components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000) }
}
#endif
