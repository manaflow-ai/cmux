import AppKit
@testable import CmuxNextPages
import CmuxNextPagesTestSupport
import Foundation
import Testing

/// Two agent chats in one Chromium renderer, one stuck in `for (;;) {}` (NIGHTLY 9d514c685e48:
/// one renderer at 100% CPU, past 14 GB, every chat in it frozen). The liveness watchdog ends that
/// renderer: both chats reload as a repair (never the crash notice), each says once that it was
/// restarted, and the log names both, since they share one main thread and the host cannot tell
/// which one loops.
@MainActor
struct PageWebViewHungRendererEndTests {
    private let root: URL
    private let descriptor = PageDescriptor(id: "test.hung-renderer", resource: "hung-renderer", namespaces: [])

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("page-hung-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<!doctype html><title>Chat</title>".utf8).write(to: root.appendingPathComponent("index.html"))
    }

    /// A chat page in Chromium under a host that shows the crash notice (the agent pane's rule).
    private func chat(_ hosting: FakeChromiumHosting, session: String, renderer: FakeRendererProcess) async throws -> (PageWebView, FakeChromiumPage) {
        let view = try #require(PageWebView(descriptor: descriptor, root: root, routes: [], chromium: hosting))
        view.chromiumClock = PageTestClock.never
        await view.chromiumStart?.value
        let page = try #require(hosting.made.last)
        page.rendererProcess = renderer
        view.reloadsAfterCrash = false
        view.logIdentity = { "session=\(session) tab=tab-\(session)" }
        return (view, page)
    }

    @Test func bothChatsOfTheEndedRendererReloadAndEachSaysItRestarted() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        let renderer = FakeRendererProcess()
        let (looping, loopingPage) = try await chat(hosting, session: "s-loop", renderer: renderer)
        let (idle, idlePage) = try await chat(hosting, session: "s-idle", renderer: renderer)
        var notices: [String] = []
        var crashNotices = 0
        for view in [looping, idle] {
            view.onRendererRestarted = { notices.append($0) }
            view.onCrash = { _, _ in crashNotices += 1 }
        }

        // The log line names both chats of the renderer.
        let entries = [looping, idle].map { $0.livenessLogEntry(visible: true, now: 100) }
        #expect(entries[0].contains("session=s-loop tab=tab-s-loop") && entries[0].contains("visible"))
        #expect(entries[1].contains("session=s-idle tab=tab-s-idle"))

        // One end, for the one renderer they share.
        #expect(PageWebView.endHungRenderer(of: [looping, idle], notice: "restarted") == 4242)
        #expect(renderer.ends == 1)

        // Chromium reports the renderer gone to both tabs: each reloads in a new renderer, no notice.
        loopingPage.onEvent?(.crashed)
        idlePage.onEvent?(.crashed)
        #expect(loopingPage.reloads == 1 && idlePage.reloads == 1, "a chat of the ended renderer did not reload")
        #expect(crashNotices == 0, "an ended renderer showed the crash notice instead of reloading")
        #expect(looping.showsChromium && idle.showsChromium, "a chat fell back to WebKit")

        // Each new document loads: its pane says once that it restarted, never silently.
        looping.documentFinished()
        idle.documentFinished()
        #expect(notices == ["restarted", "restarted"])
        looping.documentFinished()
        #expect(notices.count == 2, "a later load repeated the notice")

        // A later crash is a crash again: the notice is the person's.
        loopingPage.onEvent?(.crashed)
        #expect(crashNotices == 1 && loopingPage.reloads == 1)
        looping.close()
        idle.close()
    }

    @Test func anEndThatEndedNothingTakesTheMarksBack() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        let renderer = FakeRendererProcess()
        renderer.endAnswer = nil
        let (view, page) = try await chat(hosting, session: "s-1", renderer: renderer)
        var notices: [String] = []
        var crashNotices = 0
        view.onRendererRestarted = { notices.append($0) }
        view.onCrash = { _, _ in crashNotices += 1 }

        #expect(PageWebView.endHungRenderer(of: [view], notice: "restarted") == nil)
        // The renderer later dies on its own: that is a crash, with its notice and no reload.
        page.onEvent?(.crashed)
        #expect(crashNotices == 1 && page.reloads == 0)
        view.documentFinished()
        #expect(notices.isEmpty, "a renderer the watchdog did not end said it was restarted")
        view.close()
    }
}
