import AppKit
@testable import CmuxNextBrowser
import Foundation
import Testing

/// Lawrence's hang records (v2.2.9, 2026-10-30, seq 538: 566 ms, 563 ms CPU; v2.2.10, seq 356: 1,563 ms, 1,044 ms
/// CPU): `NSJSONSerialization dataWithJSONObject` <- the DevTools send <- `CEFTab.devTools`, on the main thread. An
/// app page's pushes and replies reach a Chromium page as one `Runtime.evaluate` script of up to 2 MiB
/// (`ChromiumPageHostBridge`), and an agent's script is as large as the agent makes it; the whole script was
/// encoded to JSON on the main actor before the shim call. Chrome builds such JSON off its UI thread
/// (services/data_decoder); its UI thread only posts the message.
///
/// Each test drives the real call path into a recording shim while a main-actor ticker records the longest
/// main-actor job (a main-thread blocking detector). The script is 8 MB: encoding it on the main actor takes far
/// more than one 60 Hz frame on a fleet Mac; sending encoded text takes well under one.
@MainActor @Suite(.serialized) struct CEFDevToolsParamsOffMainTests {
    /// The longest main-actor job a call may cause: one 60 Hz frame.
    static let budget: Duration = .milliseconds(16)
    /// Each line has quotes, a backslash and a non-ASCII letter, so the encoder escapes and transcodes.
    static let script = String(repeating: "globalThis.__cmuxPageHostResolve?.(7, {\"text\":\"a\\\\b \u{00e9}\"});\n", count: 120_000)

    @Test func aLargeScriptCallNeverHoldsTheMainActorForAFrame() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let tab = try rig.attachedTab()
        Task { _ = try? await tab.devTools(method: "Runtime.evaluate", params: ["expression": Self.script, "silent": true]) }
        let longest = await rig.longestMainActorJob { Recorder.sent(["Runtime.evaluate"]).count == 1 }
        let sent = Recorder.sent(["Runtime.evaluate"])
        #expect(sent.count == 1, "the call reaches Chromium")
        #expect(sent.first?.paramsBytes ?? 0 > Self.script.utf8.count, "with the whole script")
        #expect(longest < Self.budget, "\(Self.script.utf8.count >> 20) MB of script held the main actor \(longest) (budget \(Self.budget))")
    }

    @Test func anAgentsLargeEvaluateNeverHoldsTheMainActorForAFrame() async throws {
        // Fork API 28: an agent's script goes through DevTools Runtime.evaluate (no renderer path).
        let rig = try Rig(forkAPI: 28)
        defer { rig.close() }
        let tab = try rig.attachedTab()
        Task { _ = try? await tab.evaluate(Self.script, world: .page, gesture: .agent) }
        let longest = await rig.longestMainActorJob { Recorder.sent(["Runtime.evaluate"]).count == 1 }
        #expect(Recorder.sent(["Runtime.evaluate"]).count == 1)
        #expect(longest < Self.budget, "an agent's \(Self.script.utf8.count >> 20) MB script held the main actor \(longest) (budget \(Self.budget))")
    }

    /// A freeze and a small call made while a large call still encodes reach Chromium after it, in the order they
    /// were made: the script never runs on a page frozen after it was called.
    @Test(arguments: [Int32(28), 29])
    func callsMadeWhileALargeCallEncodesKeepTheirOrder(forkAPI: Int32) async throws {
        let rig = try Rig(forkAPI: forkAPI)
        defer { rig.close() }
        let tab = try rig.attachedTab()
        let methods: Set = ["Runtime.evaluate", "Page.setWebLifecycleState", "Network.clearBrowserCache"]
        Task { _ = try? await tab.devTools(method: "Runtime.evaluate", params: ["expression": Self.script]) }
        await Task.yield()
        #expect(tab.setFrozen(true), "a freeze behind a waiting call is accepted")
        Task { _ = try? await tab.devTools(method: "Network.clearBrowserCache", params: [:]) }
        await rig.until { Recorder.sent(methods).count == 3 }
        #expect(Recorder.sent(methods).map(\.method) == ["Runtime.evaluate", "Page.setWebLifecycleState", "Network.clearBrowserCache"])
        #expect(rig.runtime.devToolsOrder.waiting(Rig.browser) == 0, "the line empties")
    }

    @Test func aSmallCallStillGoesInItsCallersFirstTurn() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let tab = try rig.attachedTab()
        Task { _ = try? await tab.devTools(method: "Input.insertText", params: ["text": "a"]) }
        await Task.yield()
        let sent = Recorder.sent(["Input.insertText"])
        #expect(sent.map(\.params) == [#"{"text":"a"}"#], "sent in the task's first turn, as before")
    }

    /// An agent's `browser screenshot` (`CEFTab.snapshot`): the answer is a viewport PNG as base64, megabytes for a
    /// Retina window; its base64 and PNG decode must not run on the main actor.
    @Test func aLargeScreenshotAnswerIsDecodedOffTheMainActor() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let tab = try rig.attachedTab()
        let answer = try Self.screenshotAnswer(width: 3_840, height: 2_400)
        var image: CGImage?
        Task { image = try? await tab.snapshot() }
        await rig.until { Recorder.sent(["Page.captureScreenshot"]).count == 1 }
        let message = try #require(Recorder.lastMessage)
        rig.runtime.handle(.devToolsResult(browser: Rig.browser, messageID: message, success: true, json: answer))
        let longest = await rig.longestMainActorJob { image != nil }
        #expect(image?.width == 3_840, "the picture arrives")
        #expect(longest < Self.budget, "a \(answer.utf8.count >> 20) MB screenshot answer held the main actor \(longest) (budget \(Self.budget))")
    }

    /// `Page.captureScreenshot`'s result for a noisy (hard to compress) PNG of `width` x `height`.
    static func screenshotAnswer(width: Int, height: Int) throws -> String {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        var seed: UInt32 = 2_463_534_242
        for i in pixels.indices {
            seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5
            pixels[i] = i % 4 == 3 ? 255 : UInt8(truncatingIfNeeded: seed)
        }
        let image = try #require(pixels.withUnsafeMutableBytes { bytes in
            CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        })
        let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        return #"{"data":""# + png.base64EncodedString() + #""}"#
    }

    // MARK: Rig

    @MainActor final class Rig {
        static let browser: Int32 = 7
        let runtime: CEFRuntime
        let root: URL

        init(forkAPI: Int32 = 29) throws {
            Recorder.reset(forkAPI: forkAPI)
            root = FileManager.default.temporaryDirectory.appending(path: "cef-devtools-off-main-\(UUID().uuidString)", directoryHint: .isDirectory)
            runtime = CEFRuntime(shim: try Recorder.library(), storage: CEFProfileStorage(root: root))
        }

        /// A tab whose browser exists (AFTER_CREATED). On fork API 28 its bridges send their own calls (none of the
        /// methods the tests look for).
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

        /// The longest main-actor job between the ticker's turns until `done` (at most 30 s): every other job on the
        /// main actor runs between two of its turns, so a call that encodes there shows as one long gap.
        func longestMainActorJob(until done: () -> Bool) async -> Duration {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(30))
            var last = clock.now
            var longest: Duration = .zero
            repeat {
                await Task.yield()
                let now = clock.now
                longest = max(longest, last.duration(to: now))
                last = now
            } while !done() && clock.now < deadline
            return longest
        }

        func until(_ condition: () -> Bool) async {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(30))
            while !condition(), clock.now < deadline { await Task.yield() }
        }

        func close() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}

/// What the shim was asked, recorded on the main thread (the shim is called on CEF's UI thread, the main thread).
private nonisolated enum Recorder {
    struct Call { let method: String; let params: String; let paramsBytes: Int }
    nonisolated(unsafe) static var calls: [Call] = []
    nonisolated(unsafe) static var forkAPI: Int32 = 29
    nonisolated(unsafe) static var nextMessage: Int32 = 1
    /// The message id the last DevTools call got.
    nonisolated(unsafe) static var lastMessage: Int32?

    static func reset(forkAPI api: Int32) {
        forkAPI = api
        calls = []
        nextMessage = 1
        lastMessage = nil
    }

    /// The calls of `methods`, in the order they reached the shim.
    static func sent(_ methods: Set<String>) -> [Call] { calls.filter { methods.contains($0.method) } }

    static func library() throws -> CEFShimLibrary {
        let version: @convention(c) () -> Int32 = { Recorder.forkAPI }
        let createWindow: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, _, _, _, _, _ in 1 }
        let devToolsCall: @convention(c) (Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, method, params in
            let bytes = params.map { strlen($0) } ?? 0
            Recorder.calls.append(Call(method: method.map { String(cString: $0) } ?? "",
                                       params: bytes < 256 ? params.map { String(cString: $0) } ?? "" : "", paramsBytes: bytes))
            Recorder.nextMessage += 1
            Recorder.lastMessage = Recorder.nextMessage
            return Recorder.nextMessage
        }
        let freeze: @convention(c) (Int32, Int32) -> Int32 = { _, _ in
            Recorder.calls.append(Call(method: "Page.setWebLifecycleState", params: "", paramsBytes: 0))
            return 1
        }
        let nothing: @convention(c) () -> Int = { 0 }
        return try CEFShimLibrary.resolving { name in
            switch name {
            case "cmux_shim_fork_api_version": unsafeBitCast(version, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_create_window": unsafeBitCast(createWindow, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_devtools_call": unsafeBitCast(devToolsCall, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_tab_set_frozen": unsafeBitCast(freeze, to: UnsafeMutableRawPointer.self)
            default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
            }
        }
    }
}
