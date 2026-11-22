import AppKit
@testable import CmuxNextBrowser
import Foundation
import Testing

/// NIGHTLY 2026-10-29 (4499, 101+ workspaces): the main thread was busy 10-42% at idle, and more than
/// half of it was ``CEFAgentRelay/deliver(_:)``. Every raw DevTools message of a watched tab (each
/// Chromium-hosted page watches its own) went through five Foundation `String.contains` scans --
/// media, protected media, verification, design mode, first paint -- before the relay's sink saw
/// it, each one character by character over the whole message. Chrome DevTools messages are tens
/// of kilobytes (console calls, page host posts, replies), so that was 50-200 ms stalls and slow
/// Apple Event replies. The relay now reads a message's top-level method once, from its first
/// bytes, and only the bridges whose method it is look further.
///
/// The traffic below is a burst of a page's ordinary events (80 messages, about 1.3 MB), through
/// the path the shim's callback takes (`CEFRuntime.handle`). The budget is the main-thread time
/// the relay may spend on it before the sink has it: the five scans took over a hundred
/// milliseconds; the method read takes well under one.
@MainActor @Suite(.serialized) struct CEFAgentRelayDeliveryCostTests {
    /// The main-thread time the burst may cost the relay.
    static let budget: Duration = .milliseconds(25)

    @Test func aPagesDevToolsTrafficCostsTheMainThreadAlmostNothingBeforeItsSink() throws {
        let rig = try Rig()
        defer { rig.close() }
        let tab = try rig.attachedTab()
        var sunk = 0
        var bytes = 0
        tab.agentRelay.set(onMessage: { json in
            sunk += 1
            bytes += json.utf8.count
        }, onEnd: {})
        let traffic = Self.traffic()
        // Warm the lazily made bridges so the budget measures delivery only.
        rig.runtime.handle(.devToolsMessage(browser: Rig.browser, json: traffic[0]))
        sunk = 0
        bytes = 0

        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for json in traffic { rig.runtime.handle(.devToolsMessage(browser: Rig.browser, json: json)) }
        }

        #expect(sunk == traffic.count, "every message reaches the relay's sink")
        #expect(bytes == traffic.reduce(0) { $0 + $1.utf8.count })
        #expect(elapsed < Self.budget, "\(traffic.count) messages, \(bytes / 1024) KiB took \(elapsed) on the main actor (budget \(Self.budget))")
    }

    @Test func theBridgesStillTakeTheirOwnBindingCallsAndNothingElse() throws {
        let rig = try Rig()
        defer { rig.close() }
        let tab = try rig.attachedTab()
        var sunk: [String] = []
        tab.agentRelay.set(onMessage: { sunk.append($0) }, onEnd: {})
        let media = Self.event("Runtime.bindingCalled", params: ["name": BrowserMediaState.channel, "payload": "{}", "executionContextId": 1])
        let design = Self.event("Runtime.bindingCalled", params: ["name": BrowserDesignModeScript.chromiumBinding, "payload": "{}", "executionContextId": 1])
        let other = Self.event("Runtime.bindingCalled", params: ["name": "__cmuxPageHost", "payload": "{\"x\":\"\(BrowserMediaState.channel)\"}", "executionContextId": 1])
        // Not Chromium's key order (`JSONSerialization` sorts none): the method is found anyway.
        let reordered = #"{"params":{"executionContextId":1,"name":"\#(BrowserMediaState.channel)","payload":"{}"},"method":"Runtime.bindingCalled"}"#
        let reply = #"{"id":1073741825,"result":{"method":"Runtime.bindingCalled","name":"\#(BrowserMediaState.channel)"}}"#
        for json in [media, design, other, reordered, reply] { rig.runtime.handle(.devToolsMessage(browser: Rig.browser, json: json)) }
        #expect(sunk == [other, reply])
    }

    // MARK: Traffic

    /// A burst of a Chromium-hosted page's events: console calls with a long string, page host
    /// posts, lifecycle events, and raw-send replies.
    static func traffic() -> [String] {
        let preview = String(repeating: "abcdefghij", count: 1_600)
        let console = event("Runtime.consoleAPICalled", params: [
            "type": "log", "executionContextId": 3, "timestamp": 1_793_000_000.5,
            "args": [["type": "string", "value": preview]],
        ])
        let post = event("Runtime.bindingCalled", params: [
            "name": "__cmuxPageHost", "executionContextId": 3,
            "payload": #"{"name":"cmuxPage","seq":7,"body":{"op":"rows","text":"\#(preview)\#(preview)"}}"#,
        ])
        let lifecycle = event("Page.lifecycleEvent", params: ["frameId": "F1", "loaderId": "L1", "name": "networkIdle", "timestamp": 1.5])
        let reply = #"{"id":1073741901,"result":{"result":{"type":"string","value":"\#(preview)"}}}"#
        var messages: [String] = []
        for _ in 0..<20 { messages += [console, post, lifecycle, reply] }
        return messages
    }

    /// A protocol event as Chromium writes it: `method` first, then `params`.
    static func event(_ method: String, params: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: params, options: [.sortedKeys])) ?? Data("{}".utf8)
        return #"{"method":"\#(method)","params":"# + String(decoding: data, as: UTF8.self) + "}"
    }

    // MARK: Rig

    @MainActor final class Rig {
        static let browser: Int32 = 7
        let runtime: CEFRuntime
        let root: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.appending(path: "cef-relay-cost-\(UUID().uuidString)", directoryHint: .isDirectory)
            runtime = CEFRuntime(shim: try Self.library(), storage: CEFProfileStorage(root: root))
        }

        /// A tab whose browser exists (AFTER_CREATED).
        func attachedTab() throws -> CEFTab {
            let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
            let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
            host.add(tab)
            host.ensureCreated(tab)
            let request = try #require(runtime.pendingWindows.keys.first)
            runtime.handle(.afterCreated(browser: Self.browser, request: request, window: 1))
            try #require(tab.browserID == Self.browser)
            return tab
        }

        func close() {
            try? FileManager.default.removeItem(at: root)
        }

        /// A shim on fork API 29 (renderer paths, so the bridges open no DevTools session) that
        /// makes every window and answers nothing else.
        private static func library() throws -> CEFShimLibrary {
            let version: @convention(c) () -> Int32 = { 29 }
            let createWindow: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, _, _, _, _, _ in 1 }
            let nothing: @convention(c) () -> Int = { 0 }
            return try CEFShimLibrary.resolving { name in
                switch name {
                case "cmux_shim_fork_api_version": unsafeBitCast(version, to: UnsafeMutableRawPointer.self)
                case "cmux_shim_create_window": unsafeBitCast(createWindow, to: UnsafeMutableRawPointer.self)
                default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
                }
            }
        }
    }
}
