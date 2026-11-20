import AppKit
import CmuxNextDesign
@testable import CmuxNextPages
import CmuxNextPagesTestSupport
import CmuxNextTestSupport
import Foundation
import Testing

/// Two agent chats in one Chromium renderer, one stuck in `for (;;) {}` (NIGHTLY 9d514c685e48:
/// one renderer at 100% CPU, past 14 GB, every chat in it frozen). The liveness watchdog ends that
/// renderer: both chats reload as a repair (never the crash notice), each says once that it was
/// restarted, and the log names both, since they share one main thread and the host cannot tell
/// which one loops.
@MainActor @Suite(.closesItsWindows)
struct PageWebViewHungRendererEndTests {
    private let root: URL
    private let descriptor = PageDescriptor(id: "test.hung-renderer", resource: "hung-renderer", namespaces: [])

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("page-hung-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<!doctype html><title>Chat</title>".utf8).write(to: root.appendingPathComponent("index.html"))
    }

    /// A renderer with a client id no other test's renderer has: an end marks every open page of
    /// its renderer, so a shared id would reach another test's pages.
    private func newRenderer() -> FakeRendererProcess {
        FakeRendererProcess(clientID: Int32.random(in: 1_000_000...Int32.max))
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

    /// One window's toasts, as the agent panes of that window share them (``CmuxToastCenter``).
    private func window() -> NSWindow {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    @Test func bothChatsOfTheEndedRendererReloadAndEachSaysItRestarted() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        let renderer = newRenderer()
        let (looping, loopingPage) = try await chat(hosting, session: "s-loop", renderer: renderer)
        let (idle, idlePage) = try await chat(hosting, session: "s-idle", renderer: renderer)
        // Both panes in one window, so their notices go to one toast stack.
        let toasts = CmuxToastCenter()
        let window = window()
        defer { window.close() }
        var notices: [CmuxToast] = []
        var crashNotices = 0
        for view in [looping, idle] {
            view.onRendererRestarted = { toast in
                notices.append(toast)
                toasts.show(toast, in: window)
            }
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
        #expect(notices.map(\.message) == ["restarted", "restarted"])
        // Both notices show at once in the window they share: neither replaced the other.
        #expect(toasts.toasts(in: window).map(\.id) == notices.map(\.id), "one chat's restart notice replaced the other's")
        #expect(Set(notices.map(\.kind)).count == 1, "the notices are not one kind for Don't Show Again")
        looping.documentFinished()
        #expect(notices.count == 2, "a later load repeated the notice")

        // A later crash is a crash again: the notice is the person's.
        loopingPage.onEvent?(.crashed)
        #expect(crashNotices == 1 && loopingPage.reloads == 1)
        looping.close()
        idle.close()
    }

    /// A chat still booting has sent no beat, so no watchdog part times it (App Health's feed joins
    /// a page on its first beat), yet it lives in the renderer that ends: it reloads with the notice
    /// like the rest, never the crash notice. A chat in another renderer is left alone.
    @Test func aChatStillBootingInTheEndedRendererReloadsWithTheNotice() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        let renderer = newRenderer()
        let (looping, loopingPage) = try await chat(hosting, session: "s-loop", renderer: renderer)
        let (booting, bootingPage) = try await chat(hosting, session: "s-boot", renderer: renderer)
        let (other, otherPage) = try await chat(hosting, session: "s-other", renderer: newRenderer())
        var notices: [String: [String]] = [:]
        var crashNotices: [String: Int] = [:]
        for (name, view) in [("loop", looping), ("boot", booting), ("other", other)] {
            view.onRendererRestarted = { notices[name, default: []].append($0.message) }
            view.onCrash = { _, _ in crashNotices[name, default: 0] += 1 }
        }

        // The feed passes only the pages its part has (the booting one has not joined).
        #expect(PageWebView.endHungRenderer(of: [looping], notice: "restarted") == 4242)
        loopingPage.onEvent?(.crashed)
        bootingPage.onEvent?(.crashed)
        #expect(bootingPage.reloads == 1, "a booting chat of the ended renderer did not reload")
        #expect(crashNotices["boot"] == nil, "a booting chat of the ended renderer showed the crash notice")
        booting.documentFinished()
        looping.documentFinished()
        #expect(notices["boot"] == ["restarted"] && notices["loop"] == ["restarted"])

        // The other renderer's chat was not marked: its own end is a crash, with no restart line.
        otherPage.onEvent?(.crashed)
        other.documentFinished()
        #expect(crashNotices["other"] == 1 && otherPage.reloads == 0 && notices["other"] == nil)
        for view in [looping, booting, other] { view.close() }
    }

    @Test func anEndThatEndedNothingTakesTheMarksBack() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        let renderer = newRenderer()
        renderer.endAnswer = nil
        let (view, page) = try await chat(hosting, session: "s-1", renderer: renderer)
        let (booting, bootingPage) = try await chat(hosting, session: "s-2", renderer: renderer)
        var notices: [String] = []
        var crashNotices = 0
        for chat in [view, booting] {
            chat.onRendererRestarted = { notices.append($0.message) }
            chat.onCrash = { _, _ in crashNotices += 1 }
        }

        #expect(PageWebView.endHungRenderer(of: [view], notice: "restarted") == nil)
        // The renderer later dies on its own: that is a crash, with its notice and no reload, for
        // the page passed and the one it would have marked.
        page.onEvent?(.crashed)
        bootingPage.onEvent?(.crashed)
        #expect(crashNotices == 2 && page.reloads == 0 && bootingPage.reloads == 0)
        view.documentFinished()
        booting.documentFinished()
        #expect(notices.isEmpty, "a renderer the watchdog did not end said it was restarted")
        view.close()
        booting.close()
    }
}
