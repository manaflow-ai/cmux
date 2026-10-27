@testable import CmuxNextBrowser
import Darwin
import Foundation
import Testing

/// `CMUX_CEF_DEFER_EVENTS=1` (task 231 of plans/cmux-next/chrome-parity/p01-process.md): the
/// in-process backend delivers each shim event on a later main turn and answers the `mirror`
/// exports from the values the last batch pushed, as the remote shim of host mode will.
@MainActor @Suite(.serialized) struct CEFDeferredEventsTests {
    @Test func theEnvironmentTurnsTheModeOnInProcessOnly() {
        #expect(CEFDeferredEvents.requested(by: ["CMUX_CEF_DEFER_EVENTS": "1"]) != nil)
        #expect(CEFDeferredEvents.requested(by: ["CMUX_CEF_DEFER_EVENTS": "0"]) == nil)
        #expect(CEFDeferredEvents.requested(by: [:]) == nil)
        #expect(CEFDeferredEvents.requested(by: ["CMUX_CEF_DEFER_EVENTS": "1"], inHostMode: true) == nil,
                "host mode's events and mirror reads come from the wire")
    }

    @Test func anEventWaitsForALaterTurnAndEventsKeepTheirOrder() throws {
        let (runtime, turns, root) = try Self.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        runtime.siteReplyBrowsers = [7: 1, 8: 1]

        runtime.receive(.reply(browser: 1, id: 7, value: 3, json: "first"))
        runtime.receive(.reply(browser: 1, id: 8, value: 4, json: "second"))
        #expect(runtime.earlySiteReplies.isEmpty, "nothing runs inside the shim's call")
        #expect(runtime.deferredEvents?.queued == 2)
        #expect(turns.blocks.count == 1, "one turn delivers the batch")

        turns.runAll()
        #expect(runtime.earlySiteReplies[7] == CEFSiteReply(value: 3, json: "first"))
        #expect(runtime.earlySiteReplies[8] == CEFSiteReply(value: 4, json: "second"))
        #expect(runtime.deferredEvents?.queued == 0)
    }

    @Test func anEventRaisedWhileABatchIsHandledWaitsForTheNextTurn() {
        let turns = Turns()
        let deferred = CEFDeferredEvents(nextTurn: { turns.blocks.append($0) })
        var delivered: [CEFShimEvent] = []
        deferred.receive(.beforeClose(browser: 1)) { event in
            delivered.append(event)
            deferred.receive(.beforeClose(browser: 2)) { delivered.append($0) }
        }
        #expect(turns.blocks.count == 1)

        let firstTurn = turns.blocks.removeFirst()
        firstTurn()
        #expect(delivered == [.beforeClose(browser: 1)], "the raised event is not in the batch being handled")
        #expect(deferred.queued == 1)
        #expect(turns.blocks.count == 1, "the raised event has a turn of its own")

        turns.runAll()
        #expect(delivered == [.beforeClose(browser: 1), .beforeClose(browser: 2)])
    }

    @Test func withoutTheModeAnEventRunsInTheShimsCall() throws {
        MirrorSpy.reset()
        let root = Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = CEFRuntime(shim: try MirrorSpy.library(), storage: CEFProfileStorage(root: root))
        runtime.siteReplyBrowsers = [7: 1]
        MirrorSpy.windowID = 2

        runtime.receive(.reply(browser: 1, id: 7, value: 3, json: ""))
        #expect(runtime.earlySiteReplies[7] == CEFSiteReply(value: 3, json: ""))
        #expect(runtime.shim?.tabWindowID(5) == 2, "a live read")
    }

    @Test func aMirrorReadAnswersFromTheLastDeliveredBatch() throws {
        let (runtime, turns, root) = try Self.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let shim = try #require(runtime.shim)
        MirrorSpy.windowID = 2
        #expect(shim.tabWindowID(5) == 0, "no batch pushed the key")

        runtime.receive(.tab(.removed, browser: 5, window: 2, value: 0))
        MirrorSpy.windowID = 3
        #expect(shim.tabWindowID(5) == 0, "the batch is not delivered yet")
        turns.runAll()
        #expect(shim.tabWindowID(5) == 2, "the value when Chromium sent the event")
        MirrorSpy.windowID = 4
        #expect(shim.tabWindowID(5) == 2, "no event refreshed it since")
    }

    @Test func aMirrorStringIsACopyTheCallerFreesThroughTheShim() throws {
        let (runtime, turns, root) = try Self.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let shim = try #require(runtime.shim)
        #expect(shim.tabNavigationState(5) == nil)

        runtime.receive(.loadEnd(browser: 5, httpStatus: 200))
        turns.runAll()
        #expect(MirrorSpy.frees == 1, "the source's own string, read when the event came")
        MirrorSpy.navigationState = "state-B"
        #expect(shim.tabNavigationState(5) == "state-A")
        #expect(shim.tabNavigationState(5) == "state-A")
        #expect(MirrorSpy.frees == 1, "the cache's copies never reach the source's free")
    }

    @Test func theHelloCarriesEveryHostWideKey() throws {
        let (runtime, turns, root) = try Self.runtime {
            MirrorSpy.windowCount = -1
            MirrorSpy.liveBrowserCount = 3
        }
        defer { try? FileManager.default.removeItem(at: root) }
        MirrorSpy.forkAPIVersion = 30
        MirrorSpy.windowCount = 2
        #expect(runtime.forkAPIVersion == 27, "read when the shim was made")
        #expect(runtime.shim?.windowCount() == -1, "a count is in the hello too, before any event")
        #expect(runtime.shim?.liveBrowserCount() == 3)

        runtime.receive(.tab(.windowDestroyed, browser: 0, window: 9, value: 2))
        turns.runAll()
        #expect(runtime.shim?.windowCount() == 2, "TAB_EVENT 6 refreshes the count")
        #expect(runtime.forkAPIVersion == 27, "only the hello carries the fork's version")
    }

    @Test func inProcessTheCountsWaitForContextInitialized() throws {
        MirrorSpy.reset()
        MirrorSpy.windowCount = -1
        let turns = Turns()
        let deferred = CEFDeferredEvents(nextTurn: { turns.blocks.append($0) })
        let shim = deferred.serveMirror(from: try MirrorSpy.library(), helloNow: false)
        try #require(deferred.mirror != nil)
        #expect(shim.forkAPIVersion() == 27, "the capabilities are read before CefInitialize")
        #expect(shim.windowCount() == 0, "Chromium is not asked for its windows before CefInitialize")

        deferred.receive(.contextInitialized) { _ in }
        turns.runAll()
        #expect(shim.windowCount() == -1, "CONTEXT_INITIALIZED stands in for the host's hello")
    }

    @Test func aHostWideCountIsOneKeyWhicheverBrowserTheEventIsAbout() throws {
        let (runtime, turns, root) = try Self.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let deferred = try #require(runtime.deferredEvents)
        let shim = try #require(runtime.shim)

        MirrorSpy.windowCount = 1
        MirrorSpy.liveBrowserCount = 1
        deferred.receive(.afterCreated(browser: 5, request: 0, window: 2)) { _ in }
        turns.runAll()
        #expect(shim.windowCount() == 1)
        #expect(shim.liveBrowserCount() == 1)

        MirrorSpy.windowCount = 4
        MirrorSpy.liveBrowserCount = 2
        deferred.receive(.beforeClose(browser: 5)) { _ in }
        turns.runAll()
        #expect(shim.windowCount() == 4)
        #expect(shim.liveBrowserCount() == 2)
    }

    @Test func boundsAreKeyedByTheirWindow() throws {
        let (runtime, turns, root) = try Self.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let shim = try #require(runtime.shim)
        runtime.receive(.tab(.windowDestroyed, browser: 0, window: 9, value: 0))
        turns.runAll()

        #expect(shim.popupWindowBounds(9) == CEFShimBounds(result: 1, x: 10, y: 20, width: 30, height: 40))
        #expect(shim.popupWindowBounds(8).result == 0, "no batch pushed window 8")
    }

    @Test func aTestsDeliveryTakesTheShimsPathAndKeepsTheOrder() throws {
        let (runtime, turns, root) = try Self.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        MirrorSpy.windowID = 2
        runtime.receive(.tab(.inserted, browser: 5, window: 2, value: 0))
        MirrorSpy.windowID = 3
        runtime.handle(.tab(.moved, browser: 5, window: 3, value: 0))
        #expect(runtime.deferredEvents?.queued == 2, "handle waits for a later turn too")
        #expect(runtime.shim?.tabWindowID(5) == 0)

        turns.runAll()
        #expect(runtime.shim?.tabWindowID(5) == 3, "the newer batch's value is the one left")
    }

    @Test func aSecondRuntimeNeverTakesTheFirstOnesMirror() throws {
        let (first, turns, root) = try Self.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        MirrorSpy.windowID = 2
        first.receive(.tab(.inserted, browser: 5, window: 2, value: 0))
        turns.runAll()

        MirrorSpy.windowID = 7
        let second = CEFRuntime(shim: try MirrorSpy.library(), storage: CEFProfileStorage(root: root),
                                deferredEvents: CEFDeferredEvents(nextTurn: { _ in }))
        #expect(second.deferredEvents?.mirror == nil, "the C exports have one cache")
        #expect(second.shim?.tabWindowID(5) == 7, "the second runtime reads live")
        #expect(first.shim?.tabWindowID(5) == 2, "the first runtime still reads its own batch")
    }

    @Test func aMirrorReadOffTheMainThreadIsTheCZeroValue() async throws {
        let (runtime, turns, root) = try Self.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let shim = try #require(runtime.shim)
        MirrorSpy.windowID = 2
        runtime.receive(.tab(.inserted, browser: 5, window: 2, value: 0))
        runtime.receive(.loadEnd(browser: 5, httpStatus: 200))
        turns.runAll()
        #expect(shim.tabWindowID(5) == 2)

        let offMain = await Task.detached { (windowID: shim.tabWindowID(5), noState: shim.tabNavigationState(5) == nil) }.value
        #expect(offMain.windowID == 0)
        #expect(offMain.noState, "no string, and Chromium is not read either")
    }

    @Test func everyOtherExportIsTheSourcesOwn() throws {
        let (runtime, _, root) = try Self.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        runtime.shim?.closeAll()
        #expect(MirrorSpy.closeAllCalls == 1)
    }

    /// The Swift table is plans/cmux-next/chromium-host-ops.json's: every mirror export, its key,
    /// and the events whose batch refreshes it.
    @Test func theRefreshTableIsTheOpsJSONs() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: repo.appending(path: "plans/cmux-next/chromium-host-ops.json"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let events = ((json["events"] as? [[String: Any]]) ?? []) + ((json["optional_events"] as? [[String: Any]]) ?? [])
        var kinds: [String: Int32] = [:]
        for event in events {
            if let kind = event["kind"] as? String, let value = event["value"] as? Int { kinds[kind] = Int32(value) }
        }
        let mirrors = try #require(json["exports"] as? [[String: Any]]).filter { $0["class"] as? String == "mirror" }
        #expect(mirrors.count == CEFMirrorField.allCases.count)
        for export in mirrors {
            let key = try #require(export["mirror_key"] as? String)
            let field = try #require(CEFMirrorField(rawValue: key), "\(key) is a CEFMirrorField")
            #expect(field.export == export["name"] as? String)
            let refresh = try #require(export["refresh_events"] as? [String])
            #expect(field.isHostWide == refresh.contains("attach"), "\(key)")
            #expect(CEFMirrorField.refreshed(by: .hello).contains(field) == refresh.contains("attach"), "\(key) is in the hello")
            var triggers: Set<CEFMirrorTrigger> = []
            for name in refresh where name != "attach" {
                let parts = name.split(separator: ":").map(String.init)
                let kind = try #require(kinds[parts[0]], "\(parts[0]) is an event kind")
                triggers.insert(CEFMirrorTrigger(kind: kind, tabEvent: parts.count > 1 ? Int32(parts[1]) : nil))
            }
            #expect(field.refreshEvents == triggers, "\(key)")
        }
    }

    // MARK: Fixtures

    /// Blocks the mode scheduled, run when the test says.
    @MainActor final class Turns {
        var blocks: [@MainActor @Sendable () -> Void] = []

        func runAll() {
            while !blocks.isEmpty {
                let block = blocks.removeFirst()
                block()
            }
        }
    }

    /// A spy runtime in the mode with its mirror served; `setUp` sets the spy's values for the hello.
    private static func runtime(setUp: () -> Void = {}) throws -> (CEFRuntime, Turns, URL) {
        MirrorSpy.reset()
        setUp()
        let root = scratch()
        let turns = Turns()
        let deferred = CEFDeferredEvents(nextTurn: { turns.blocks.append($0) })
        let runtime = CEFRuntime(shim: try MirrorSpy.library(), storage: CEFProfileStorage(root: root), deferredEvents: deferred)
        try #require(deferred.mirror != nil, "no earlier test's runtime still holds the served cache")
        return (runtime, turns, root)
    }

    private static func scratch() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "cef-deferred-events-\(UUID().uuidString)", directoryHint: .isDirectory)
    }
}

/// Stand-in shim: `cmux_shim_tab_window_id(5)`, `cmux_shim_window_count`, `cmux_shim_live_browser_count`,
/// `cmux_shim_fork_api_version` and `cmux_shim_tab_navigation_state(5)` (a `strdup` freed by
/// `cmux_shim_free`, which counts) answer from the statics; `cmux_shim_popup_window_bounds(9)` is
/// (10, 20, 30, 40); `cmux_shim_close_all` counts; every other function does nothing and returns 0.
private nonisolated enum MirrorSpy {
    // Test-only statics, written and read on the main thread by one serialized suite (the
    // off-main test reads none: the mirror export answers before the source is reached).
    nonisolated(unsafe) static var windowID: Int32 = 0 // crash-allow: main thread only, one serialized suite
    nonisolated(unsafe) static var windowCount: Int32 = 0 // crash-allow: main thread only, one serialized suite
    nonisolated(unsafe) static var liveBrowserCount: Int32 = 0 // crash-allow: main thread only, one serialized suite
    nonisolated(unsafe) static var forkAPIVersion: Int32 = 27 // crash-allow: main thread only, one serialized suite
    nonisolated(unsafe) static var navigationState = "state-A" // crash-allow: main thread only, one serialized suite
    nonisolated(unsafe) static var frees = 0 // crash-allow: main thread only, one serialized suite
    nonisolated(unsafe) static var closeAllCalls = 0 // crash-allow: main thread only, one serialized suite

    static func reset() {
        windowID = 0
        windowCount = 0
        liveBrowserCount = 0
        forkAPIVersion = 27
        navigationState = "state-A"
        frees = 0
        closeAllCalls = 0
    }

    static func library() throws -> CEFShimLibrary {
        let windowID: @convention(c) (Int32) -> Int32 = { browser in browser == 5 ? MirrorSpy.windowID : 0 }
        let windowCount: @convention(c) () -> Int32 = { MirrorSpy.windowCount }
        let liveBrowserCount: @convention(c) () -> Int32 = { MirrorSpy.liveBrowserCount }
        let forkAPIVersion: @convention(c) () -> Int32 = { MirrorSpy.forkAPIVersion }
        let navigationState: @convention(c) (Int32) -> UnsafeMutablePointer<CChar>? = { browser in
            browser == 5 ? strdup(MirrorSpy.navigationState) : nil
        }
        let free: @convention(c) (UnsafeMutablePointer<CChar>?) -> Void = { pointer in
            MirrorSpy.frees += 1
            Darwin.free(pointer)
        }
        let popupBounds: @convention(c) (Int32, UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<Int32>?,
                                         UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<Int32>?) -> Int32 = { window, x, y, width, height in
            guard window == 9 else { return 0 }
            x?.pointee = 10
            y?.pointee = 20
            width?.pointee = 30
            height?.pointee = 40
            return 1
        }
        let closeAll: @convention(c) () -> Void = { MirrorSpy.closeAllCalls += 1 }
        let nothing: @convention(c) () -> Int = { 0 }
        return try CEFShimLibrary.resolving { name in
            switch name {
            case "cmux_shim_tab_window_id": unsafeBitCast(windowID, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_window_count": unsafeBitCast(windowCount, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_live_browser_count": unsafeBitCast(liveBrowserCount, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_fork_api_version": unsafeBitCast(forkAPIVersion, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_tab_navigation_state": unsafeBitCast(navigationState, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_free": unsafeBitCast(free, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_popup_window_bounds": unsafeBitCast(popupBounds, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_close_all": unsafeBitCast(closeAll, to: UnsafeMutableRawPointer.self)
            default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
            }
        }
    }
}
