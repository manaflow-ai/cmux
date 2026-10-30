import AppKit
@testable import CmuxNextBrowser
@testable import CmuxNextCompat
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

/// A DevTools call's parameters and its result can be megabytes: the agent chat page's transport frames reach the
/// page as one `Runtime.evaluate` script (`ChromiumPageHostBridge`), and an agent's page text or a page picture comes
/// back as one result. The main thread only sends the call; the JSON is built and parsed off it, as Chrome keeps
/// large JSON and image decodes off its UI thread (services/data_decoder/public/cpp/data_decoder.h). Hang report
/// v229 (2026-10-30): `CEFRuntime.sendDevTools` took 566 ms of the main thread encoding one such script. The main
/// thread's CPU gate (`cpuIntensiveCall`) records any of this work still done there. Against a spy shim on the
/// DevTools path (fork API 24, no renderer paths).
@MainActor @Suite(.serialized) struct CEFDevToolsOffMainTests {
    @Test func aLargeCallsParametersAreEncodedOffTheMainThread() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let script = Self.largeScript
        let table = BlockingViolationTable(mode: .record)
        let call = BlockingViolationTable.$scoped.withValue(table) {
            Task { try await rig.runtime.devTools(7, method: "Runtime.evaluate", params: ["expression": script, "silent": true]) }
        }
        _ = try await call.value
        await table.flush()

        #expect(table.sites.filter { $0.kind == .cpuIntensive }.isEmpty, "the parameters were encoded on the main thread: \(table.sites)")
        #expect(DevToolsSpy.calls.map(\.method) == ["Runtime.evaluate"])
        let sent = try #require(DevToolsSpy.calls.first)
        let params = try #require(JSONSerialization.jsonObject(with: Data(sent.params.utf8)) as? [String: Any])
        #expect(params["expression"] as? String == script, "the script reached Chromium whole")
        #expect(params["silent"] as? Bool == true)
    }

    @Test func aLargeEvaluationIsParsedOffTheMainThread() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let tab = try rig.attachedTab()
        let text = Self.largeScript
        DevToolsSpy.answers["Runtime.evaluate"] = try Self.json(["result": ["type": "string", "value": text]])
        let table = BlockingViolationTable(mode: .record)
        let evaluation = BlockingViolationTable.$scoped.withValue(table) {
            Task { try await tab.evaluate("document.body.innerText", world: .page, gesture: .cmux) }
        }
        let value = try await evaluation.value
        await table.flush()

        #expect(table.sites.filter { $0.kind == .cpuIntensive }.isEmpty, "the result was parsed on the main thread: \(table.sites)")
        #expect(value == .string(text))
    }

    @Test func aPagePictureIsDecodedOffTheMainThread() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let tab = try rig.attachedTab()
        DevToolsSpy.answers["Page.captureScreenshot"] = try Self.json(["data": try Self.png(side: 512).base64EncodedString()])
        let table = BlockingViolationTable(mode: .record)
        let snapshot = BlockingViolationTable.$scoped.withValue(table) {
            Task { try await tab.snapshot() }
        }
        let image = try await snapshot.value
        await table.flush()

        #expect(table.sites.filter { $0.kind == .cpuIntensive }.isEmpty, "the picture was decoded on the main thread: \(table.sites)")
        #expect(image.width == 512 && image.height == 512)
    }

    /// Encoding off the main thread keeps the order of the calls: a page host's reply sent after a large script
    /// reaches the page after it, as when each call was sent in its caller's turn. Another browser's calls do not
    /// wait for it.
    @Test func callsReachChromiumInTheOrderTheyWereMade() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let large = Task { try await rig.runtime.devTools(7, method: "Runtime.evaluate", params: ["expression": Self.largeScript]) }
        let small = Task { try await rig.runtime.devTools(7, method: "Runtime.addBinding", params: ["name": "__cmuxPageHost"]) }
        let last = Task { try await rig.runtime.devTools(7, method: "Page.enable") }
        let other = Task { try await rig.runtime.devTools(8, method: "Page.enable") }
        _ = try await (large.value, small.value, last.value, other.value)

        #expect(DevToolsSpy.calls.filter { $0.browser == 7 }.map(\.method) == ["Runtime.evaluate", "Runtime.addBinding", "Page.enable"])
        #expect(DevToolsSpy.calls.filter { $0.browser == 8 }.map(\.method) == ["Page.enable"])
    }

    /// A one-way call made while an earlier call to the same browser still encodes reaches Chromium after it. For the
    /// agent chat page that earlier call is a batch of chat frames: a freeze that overtook it left the batch's script
    /// to run on a frozen page, where its wait ran out and the frames never showed.
    @Test func aFreezeMadeWhileALargeCallEncodesReachesChromiumAfterIt() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let tab = try rig.attachedTab()
        DevToolsSpy.calls = []
        let evaluate = Task { try await rig.runtime.devTools(7, method: "Runtime.evaluate", params: ["expression": Self.largeScript]) }
        await rig.until { rig.runtime.devToolsOrder.waiting(7) > 0 }
        try #require(DevToolsSpy.calls.isEmpty, "the evaluate is still encoding")
        #expect(tab.setFrozen(true))
        _ = try await evaluate.value
        await rig.until { DevToolsSpy.calls.count >= 2 }
        #expect(DevToolsSpy.calls.map(\.method) == ["Runtime.evaluate", "Page.setWebLifecycleState"])
    }

    @Test func aCommandMadeWhileALargeCallEncodesReachesChromiumAfterIt() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let tab = try rig.attachedTab()
        DevToolsSpy.calls = []
        let evaluate = Task { try await rig.runtime.devTools(7, method: "Runtime.evaluate", params: ["expression": Self.largeScript]) }
        await rig.until { rig.runtime.devToolsOrder.waiting(7) > 0 }
        try #require(DevToolsSpy.calls.isEmpty, "the evaluate is still encoding")
        #expect(tab.perform("document.execCommand('copy')", gesture: .agent))
        _ = try await evaluate.value
        await rig.until { DevToolsSpy.calls.count >= 2 }
        #expect(DevToolsSpy.calls.map { $0.params.contains("execCommand") } == [false, true])
    }

    /// On the fork's renderer paths a page's own scripts go by `tabEvaluate`, not DevTools: they keep the browser's
    /// order too. A command and then a script, made while a large call still encodes, reach the page after it and in
    /// the order they were made.
    @Test func aForkEvaluationMadeWhileALargeCallEncodesReachesThePageInOrder() async throws {
        let rig = try Rig(forkAPI: 29)
        defer { rig.close() }
        let tab = try rig.attachedTab()
        try #require(rig.runtime.forkFeatures.rendererPaths)
        DevToolsSpy.calls = []
        let large = Task { try await rig.runtime.devTools(7, method: "Runtime.evaluate", params: ["expression": Self.largeScript]) }
        await rig.until { rig.runtime.devToolsOrder.waiting(7) > 0 }
        try #require(DevToolsSpy.calls.isEmpty, "the large call is still encoding")
        #expect(tab.perform("command()", gesture: .agent))
        rig.runtime.evaluateLatest(7, world: "", script: "lookUp()") { _ in }
        let evaluated = Task { try await rig.runtime.evaluate(7, world: "", script: "read()", userGesture: false) }
        _ = try await large.value
        _ = try await evaluated.value
        #expect(DevToolsSpy.calls.map(\.method) == ["Runtime.evaluate", "tabEvaluate", "tabEvaluate", "tabEvaluate"])
        #expect(DevToolsSpy.calls.dropFirst().map(\.params) == ["command()", "lookUp()", "read()"])
    }

    /// A tab's hover picture is asked for in the turn before its content hides (a pane switch). Queued behind a large
    /// call, it still leaves, before the hide: the hidden check was made when it was asked for, as before the order.
    @Test func aPictureAskedForBeforeAHideLeavesWhenItsTurnComes() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let tab = try rig.attachedTab()
        DevToolsSpy.calls = []
        let large = Task { try await rig.runtime.devTools(7, method: "Runtime.evaluate", params: ["expression": Self.largeScript]) }
        await rig.until { rig.runtime.devToolsOrder.waiting(7) > 0 }
        try #require(DevToolsSpy.calls.isEmpty, "the large call is still encoding")
        let picture = tab.beginThumbnail()
        tab.setContentVisible(false)
        _ = try await large.value
        _ = try? await picture.image()
        #expect(DevToolsSpy.calls.map(\.method) == ["Runtime.evaluate", "Page.captureScreenshot"])
    }

    // MARK: Fixtures

    /// About 300 KB of a page host script with non-ASCII text, as an agent chat's transport frames.
    static let largeScript = "window.__cmuxPageReceiveMany(["
        + String(repeating: #"{"frame":"résumé \"quoted\" ✓","n":1},"#, count: 8_000) + "{}]);"

    static func json(_ object: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    /// A `side` x `side` PNG: its decoded pixels (`side`² x 4 bytes) are above the main thread's image gate.
    static func png(side: Int) throws -> Data {
        let context = try #require(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
        return data as Data
    }

    // MARK: Rig

    @MainActor final class Rig {
        let runtime: CEFRuntime
        let root: URL

        init(forkAPI: Int32 = 24) throws {
            DevToolsSpy.reset()
            DevToolsSpy.forkAPI = forkAPI
            root = FileManager.default.temporaryDirectory.appending(path: "cef-devtools-off-main-\(UUID().uuidString)", directoryHint: .isDirectory)
            runtime = CEFRuntime.spy(shim: try DevToolsSpy.library(), storage: CEFProfileStorage(root: root))
            DevToolsSpy.runtime = runtime
        }

        /// A tab whose browser 7 exists (AFTER_CREATED).
        func attachedTab() throws -> CEFTab {
            let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
            let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
            host.add(tab)
            host.ensureCreated(tab)
            let request = try #require(runtime.pendingWindows.keys.first)
            runtime.handle(.afterCreated(browser: 7, request: request, window: 1))
            try #require(tab.browserID == 7)
            return tab
        }

        /// Lets main-actor work run until `condition` (at most 500 turns).
        func until(_ condition: () -> Bool) async {
            for _ in 0..<500 where !condition() { await Task.yield() }
        }

        func close() {
            DevToolsSpy.runtime = nil
            try? FileManager.default.removeItem(at: root)
        }
    }
}

/// The DevTools calls the runtime sends, recorded; each is answered inside the call, as Chromium answers a method the
/// browser process handles at once (in the deferred-event mode the answer comes a turn later).
private nonisolated enum DevToolsSpy {
    struct Call {
        let browser: Int32
        let method: String
        let params: String
    }

    nonisolated(unsafe) static var calls: [Call] = []
    /// The result JSON by method; "{}" for any other.
    nonisolated(unsafe) static var answers: [String: String] = [:]
    nonisolated(unsafe) static var nextMessage: Int32 = 1
    nonisolated(unsafe) static weak var runtime: CEFRuntime?
    nonisolated(unsafe) static var forkAPI: Int32 = 24

    static func reset() {
        calls = []
        answers = [:]
        nextMessage = 1
    }

    static func text(_ pointer: UnsafePointer<CChar>?) -> String {
        pointer.map { String(cString: $0) } ?? ""
    }

    static func library() throws -> CEFShimLibrary {
        let version: @convention(c) () -> Int32 = { DevToolsSpy.forkAPI }
        let createWindow: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, _, _, _, _, _ in 1 }
        let devToolsCall: @convention(c) (Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { browser, method, params in
            let name = DevToolsSpy.text(method)
            DevToolsSpy.calls.append(Call(browser: browser, method: name, params: DevToolsSpy.text(params)))
            let message = DevToolsSpy.nextMessage
            DevToolsSpy.nextMessage += 1
            let answer = DevToolsSpy.answers[name] ?? "{}"
            MainActor.assumeIsolated { // main-proof: the runtime calls the shim on the main thread only
                DevToolsSpy.runtime?.handle(.devToolsResult(browser: browser, messageID: message, success: true, json: answer))
            }
            return message
        }
        // The fork's evaluate (renderer paths): recorded as "tabEvaluate" with its script, answered inside the call.
        let tabEvaluate: @convention(c) (Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?, Int32) -> Int32 = { browser, token, _, script, _ in
            DevToolsSpy.calls.append(Call(browser: browser, method: "tabEvaluate", params: DevToolsSpy.text(script)))
            MainActor.assumeIsolated { // main-proof: the runtime calls the shim on the main thread only
                DevToolsSpy.runtime?.handle(.evaluateResult(token: token, status: 0, value: "null"))
            }
            return 1
        }
        let nothing: @convention(c) () -> Int = { 0 }
        return try CEFShimLibrary.resolving { name in
            switch name {
            case "cmux_shim_fork_api_version": unsafeBitCast(version, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_create_window": unsafeBitCast(createWindow, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_devtools_call": unsafeBitCast(devToolsCall, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_tab_evaluate": unsafeBitCast(tabEvaluate, to: UnsafeMutableRawPointer.self)
            default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
            }
        }
    }
}
