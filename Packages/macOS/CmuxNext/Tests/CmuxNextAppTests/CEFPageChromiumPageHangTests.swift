import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import CmuxNextPages
import CmuxNextWakeups
import Foundation
import Testing

/// A cmux page in Chromium forwards its renderer's hang to the page host as
/// Chrome's `RendererUnresponsive` / `RendererResponsive` pair (chrome/browser/ui/browser.cc), only
/// with a hang scheduler (feature `pageHangNotice`), once per hang, and answers it through the shim's
/// `cmux_shim_unresponsive_reply`. The shim's RENDER_UNRESPONSIVE / RESPONSIVE events go through the
/// real runtime, tab and page; the shim is a spy.
@MainActor @Suite(.serialized) struct CEFPageChromiumPageHangTests {
    @Test func aHangAndItsEndReachTheHostOnceEach() throws {
        let rig = try PageHangRig()
        defer { rig.close() }
        let page = try rig.page(browser: 7, hangWork: linklessMainWork())
        var events: [PageChromiumEvent] = []
        page.onEvent = { if Self.isHang($0) { events.append($0) } }
        #expect(events.isEmpty, "a renderer that never hung reports nothing")

        rig.runtime.handle(.renderUnresponsive(browser: 7))
        rig.runtime.handle(.renderUnresponsive(browser: 7))
        #expect(runMainLoop { !events.isEmpty })
        rig.runtime.handle(.renderResponsive(browser: 7))
        #expect(runMainLoop { events.count >= 2 })
        #expect(events == [.unresponsive, .responsive], "one event for the hang, one for its end")

        rig.runtime.handle(.renderUnresponsive(browser: 7))
        #expect(runMainLoop { events.count >= 3 })
        #expect(events == [.unresponsive, .responsive, .unresponsive], "a second hang after the first ended reports again")
    }

    @Test func withoutAHangSchedulerTheHangNeverReachesTheHost() throws {
        let rig = try PageHangRig()
        defer { rig.close() }
        let silent = try rig.page(browser: 7, hangWork: nil)
        let forwarding = try rig.page(browser: 8, hangWork: linklessMainWork())
        var silentEvents: [PageChromiumEvent] = []
        var forwardedEvents: [PageChromiumEvent] = []
        silent.onEvent = { if Self.isHang($0) { silentEvents.append($0) } }
        forwarding.onEvent = { if Self.isHang($0) { forwardedEvents.append($0) } }

        rig.runtime.handle(.renderUnresponsive(browser: 7))
        rig.runtime.handle(.renderUnresponsive(browser: 8))
        #expect(silent.tab.state.isUnresponsive, "the tab itself saw the hang")
        // The forwarding page's flush proves the main run loop ran past the silent page's chance.
        #expect(runMainLoop { forwardedEvents == [.unresponsive] })
        #expect(silentEvents.isEmpty, "feature off: the page forwards no hang")

        rig.runtime.handle(.renderResponsive(browser: 7))
        rig.runtime.handle(.renderResponsive(browser: 8))
        #expect(runMainLoop { forwardedEvents == [.unresponsive, .responsive] })
        #expect(silentEvents.isEmpty, "feature off: the page forwards no end of a hang")
    }

    @Test func waitRepliesToTheShimAndTheNextHangReportsAgain() throws {
        let rig = try PageHangRig()
        defer { rig.close() }
        let page = try rig.page(browser: 7, hangWork: linklessMainWork())
        var events: [PageChromiumEvent] = []
        page.onEvent = { if Self.isHang($0) { events.append($0) } }

        rig.runtime.handle(.renderUnresponsive(browser: 7))
        #expect(runMainLoop { events == [.unresponsive] })
        page.answerUnresponsive(terminate: false)
        #expect(PageHangSpy.replies.count == 1)
        #expect(PageHangSpy.replies.first?.browser == 7)
        #expect(PageHangSpy.replies.first?.terminate == 0, "Wait restarts Chromium's hang timer")
        #expect(runMainLoop { events == [.unresponsive, .responsive] }, "Wait takes the hang down")

        // Chromium's restarted timer fires again while the page still hangs.
        rig.runtime.handle(.renderUnresponsive(browser: 7))
        #expect(runMainLoop { events == [.unresponsive, .responsive, .unresponsive] }, "the report after Wait is not deduped")
    }

    @Test func exitPageAsksTheShimToEndTheRenderer() throws {
        let rig = try PageHangRig()
        defer { rig.close() }
        let page = try rig.page(browser: 7, hangWork: linklessMainWork())
        var events: [PageChromiumEvent] = []
        page.onEvent = { if Self.isHang($0) { events.append($0) } }

        rig.runtime.handle(.renderUnresponsive(browser: 7))
        #expect(runMainLoop { events == [.unresponsive] })
        page.answerUnresponsive(terminate: true)
        #expect(PageHangSpy.replies.count == 1)
        #expect(PageHangSpy.replies.first?.browser == 7)
        #expect(PageHangSpy.replies.first?.terminate == 1)
    }

    @Test func aHostThatListensAgainLearnsOfTheStandingHang() throws {
        let rig = try PageHangRig()
        defer { rig.close() }
        let page = try rig.page(browser: 7, hangWork: linklessMainWork())
        var events: [PageChromiumEvent] = []
        page.onEvent = { if Self.isHang($0) { events.append($0) } }
        rig.runtime.handle(.renderUnresponsive(browser: 7))
        #expect(runMainLoop { events == [.unresponsive] })

        page.onEvent = nil
        var again: [PageChromiumEvent] = []
        page.onEvent = { if Self.isHang($0) { again.append($0) } }
        #expect(again == [.unresponsive], "the dedupe resets when the host stops listening")
    }

    @Test func aClosedPageAnswersNothing() throws {
        let rig = try PageHangRig()
        defer { rig.close() }
        let page = try rig.page(browser: 7, hangWork: linklessMainWork())
        var events: [PageChromiumEvent] = []
        page.onEvent = { if Self.isHang($0) { events.append($0) } }
        rig.runtime.handle(.renderUnresponsive(browser: 7))
        #expect(runMainLoop { events == [.unresponsive] })

        page.close()
        page.answerUnresponsive(terminate: true)
        #expect(PageHangSpy.replies.isEmpty)
    }

    private static func isHang(_ event: PageChromiumEvent) -> Bool {
        event == .unresponsive || event == .responsive
    }

    @MainActor final class PageHangRig {
        let runtime: CEFRuntime
        let root: URL

        init() throws {
            PageHangSpy.reset()
            root = FileManager.default.temporaryDirectory.appending(path: "cef-page-hang-\(UUID().uuidString)", directoryHint: .isDirectory)
            runtime = CEFRuntime(shim: try PageHangSpy.library(), storage: CEFProfileStorage(root: root))
        }

        /// A page whose tab's browser `browser` exists (AFTER_CREATED), forwarding hangs on `hangWork`.
        func page(browser: Int32, hangWork: MainWorkScheduler?) throws -> CEFPageChromiumPage {
            let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
            let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
            host.add(tab)
            let pending = Set(runtime.pendingWindows.keys)
            host.ensureCreated(tab)
            let request = try #require(runtime.pendingWindows.keys.first { !pending.contains($0) })
            runtime.handle(.afterCreated(browser: browser, request: request, window: 1))
            try #require(tab.browserID == browser)
            return CEFPageChromiumPage(tab: tab, pageID: "cmux.apps", mainWork: hangWork ?? MainWorkScheduler(budget: MainFrameBudget()),
                                       hangWork: hangWork)
        }

        func close() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}

/// The shim's hang replies, recorded; every other function does nothing.
private nonisolated enum PageHangSpy {
    nonisolated(unsafe) static var replies: [(browser: Int32, terminate: Int32)] = []

    static func reset() {
        replies = []
    }

    static func library() throws -> CEFShimLibrary {
        let version: @convention(c) () -> Int32 = { 29 }
        let createWindow: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, _, _, _, _, _ in 1 }
        let reply: @convention(c) (Int32, Int32) -> Int32 = { browser, terminate in
            PageHangSpy.replies.append((browser, terminate))
            return 1
        }
        let nothing: @convention(c) () -> Int = { 0 }
        return try CEFShimLibrary.resolving { name in
            switch name {
            case "cmux_shim_fork_api_version": unsafeBitCast(version, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_create_window": unsafeBitCast(createWindow, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_unresponsive_reply": unsafeBitCast(reply, to: UnsafeMutableRawPointer.self)
            default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
            }
        }
    }
}
