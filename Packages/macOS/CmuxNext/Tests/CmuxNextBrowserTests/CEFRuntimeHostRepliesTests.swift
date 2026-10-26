@testable import CmuxNextBrowser
import Foundation
import Testing

/// The token form of the async exports in CEFRuntime (task 021 of
/// plans/cmux-next/chrome-parity/p01-process.md): in process a call returns its answer; in host mode
/// it returns once sent and the answer comes in the host's REPLY under
/// `cmux_remote_shim_last_reply_token()` (task 018). Against a spy shim whose async exports record
/// their calls and hand out tokens, and replies resolved by hand.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct CEFRuntimeHostRepliesTests {
    // MARK: In process: the call is the answer

    @Test func inProcessTheCallIsTheAnswer() async throws {
        RepliesSpy.reset()
        RepliesSpy.contentSettingResult = CEFContentSetting.block.rawValue
        let runtime = try Self.runtime(host: false)

        let sent = runtime.sendAsync { shim in shim.contentSetting(1, nil, "camera") }
        guard case .now(let raw) = sent else {
            Issue.record("in process sent \(sent), expected .now")
            return
        }
        #expect(raw == CEFContentSetting.block.rawValue)
        #expect(await runtime.contentSetting(1, url: nil, kind: .camera) == .block)
    }

    @Test func inProcessAProfileProxyGateIsDecidedInTheCall() throws {
        RepliesSpy.reset()
        let runtime = try Self.runtime(host: false)
        let profile = Self.proxied(runtime)

        #expect(runtime.applyProfileProxy(profile) == .open)
        #expect(RepliesSpy.proxyServers == ["http://proxy.test:8080"])
        #expect(runtime.profileProxyChecks.isEmpty, "in process kept a host verdict")

        runtime.unappliedProfileProxies.insert(profile)
        RepliesSpy.setProxyResult = 0
        #expect(runtime.applyProfileProxy(profile) == .refused)
        #expect(runtime.unappliedProfileProxies.contains(profile), "a refused proxy is not handed over again")
    }

    // MARK: Host mode: the REPLY is the answer

    @Test func hostModeAnAwaitedAnswerIsTheReplyOfTheToken() async throws {
        RepliesSpy.reset()
        let runtime = try Self.runtime(host: true)
        let route = try #require(runtime.hostReplies)

        let sent = runtime.sendAsync { shim in shim.contentSetting(1, nil, "camera") }
        guard case .later(let token) = sent else {
            Issue.record("host mode sent \(sent), expected .later")
            return
        }
        #expect(token == RepliesSpy.lastToken)
        let answer = Task { try await runtime.answer(sent, label: "content setting") }
        await Self.untilExpected(route.replies, count: 1)
        route.deliver(token, fields: Self.int32(CEFContentSetting.allow.rawValue))

        #expect(try await answer.value == CEFContentSetting.allow.rawValue)
        #expect(route.replies.count == 0)
    }

    @Test func hostModeContentSettingIsTheHostsAnswer() async throws {
        RepliesSpy.reset()
        let runtime = try Self.runtime(host: true)
        let route = try #require(runtime.hostReplies)

        let asked = Task { await runtime.contentSetting(1, url: "https://a.test", kind: .camera) }
        await Self.untilExpected(route.replies, count: 1)
        route.deliver(RepliesSpy.lastToken, fields: Self.int32(CEFContentSetting.ask.rawValue))

        #expect(await asked.value == .ask)
    }

    /// A caller in a synchronous turn gets the answer in the turn that delivers the REPLY: no task.
    @Test func hostModeACallbackRunsInTheReplysTurn() throws {
        RepliesSpy.reset()
        let runtime = try Self.runtime(host: true)
        let route = try #require(runtime.hostReplies)
        var seen: [CEFContentSetting?] = []

        runtime.contentSetting(1, url: nil, kind: .camera) { seen.append($0) }
        #expect(seen.isEmpty, "the callback ran before the host answered")
        route.deliver(RepliesSpy.lastToken, fields: Self.int32(CEFContentSetting.block.rawValue))
        #expect(seen == [.block])
        route.deliver(RepliesSpy.lastToken, fields: Self.int32(CEFContentSetting.allow.rawValue))
        #expect(seen == [.block], "a callback ran twice")

        runtime.contentSetting(1, url: nil, kind: .camera) { seen.append($0) }
        route.deliver(RepliesSpy.lastToken, fields: Self.int32(1) + Self.int32(2))
        #expect(seen == [.block, nil], "a reply of the wrong shape is no answer")

        runtime.contentSetting(1, url: nil, kind: .camera) { seen.append($0) }
        route.hostGone()
        #expect(seen == [.block, nil, nil], "the host's exit left a callback waiting")
    }

    @Test func inProcessACallbackRunsInTheCall() throws {
        RepliesSpy.reset()
        RepliesSpy.contentSettingResult = CEFContentSetting.allow.rawValue
        let runtime = try Self.runtime(host: false)
        var seen: [CEFContentSetting?] = []

        runtime.contentSetting(1, url: nil, kind: .camera) { seen.append($0) }

        #expect(seen == [.allow])
    }

    @Test func hostModeNothingSentIsClosed() async throws {
        RepliesSpy.reset()
        RepliesSpy.sendsNothing = true
        let runtime = try Self.runtime(host: true)

        let sent = runtime.sendAsync { shim in shim.contentSetting(1, nil, "camera") }
        guard case .unsent = sent else {
            Issue.record("sent \(sent), expected .unsent")
            return
        }
        await #expect(throws: BrowserTabError.closed) { try await runtime.answer(sent, label: "content setting") }
        #expect(await runtime.contentSetting(1, url: nil, kind: .camera) == nil)
    }

    /// A CMUX_SHIM_REPLY op whose start the host refused fails at once, not at the 5 s deadline.
    @Test func hostModeARefusedStartFailsTheSiteCallAtOnce() async throws {
        RepliesSpy.reset()
        let runtime = try Self.runtime(host: true)
        let route = try #require(runtime.hostReplies)

        let visit = Task { try await runtime.cookies(1) }
        await Self.untilExpected(route.replies, count: 1)
        #expect(RepliesSpy.visits == 1)
        route.deliver(RepliesSpy.lastToken, fields: Self.int32(0))

        await #expect(throws: BrowserTabError.closed) { try await visit.value }
    }

    /// The site reply may come before the start's REPLY: it waits in earlySiteReplies.
    @Test func hostModeAStartedSiteCallTakesItsSiteReply() async throws {
        RepliesSpy.reset()
        let runtime = try Self.runtime(host: true)
        let route = try #require(runtime.hostReplies)

        let visit = Task { try await runtime.deleteCookies(1, url: "https://a.test/", name: nil) }
        await Self.untilExpected(route.replies, count: 1)
        let id = try #require(runtime.siteReplyBrowsers.keys.first)
        // The CMUX_SHIM_REPLY event under the site reply id, as CEFRuntime+Events handles it.
        runtime.earlySiteReplies[id] = CEFSiteReply(value: 3, json: "")
        route.deliver(RepliesSpy.lastToken, fields: Self.int32(1))

        #expect(try await visit.value == 3)
    }

    /// No page of a proxied profile opens before the host applied its proxy (fail closed).
    @Test func hostModeAProfileProxyWaitsForBothVerdicts() throws {
        RepliesSpy.reset()
        let runtime = try Self.runtime(host: true)
        let route = try #require(runtime.hostReplies)
        let profile = Self.proxied(runtime)
        var verdicts: [Bool] = []

        #expect(runtime.applyProfileProxy(profile) == .waiting)
        #expect(RepliesSpy.proxyServers == ["http://proxy.test:8080"])
        #expect(RepliesSpy.tokens.count == 2, "the proxy and its state were not both sent")
        runtime.whenProfileProxyApplied(profile) { verdicts.append($0) }
        #expect(RepliesSpy.proxyServers.count == 1, "a second page sent the proxy again")

        route.deliver(RepliesSpy.tokens[0], fields: Self.int32(1))
        #expect(verdicts.isEmpty, "the page opened before the proxy's state came")
        route.deliver(RepliesSpy.tokens[1], fields: Self.int32(0))

        #expect(verdicts == [true])
        #expect(runtime.applyProfileProxy(profile) == .open)
        #expect(RepliesSpy.tokens.count == 2, "an applied proxy was asked again")
    }

    @Test func hostModeARefusedProfileProxyFailsClosedAndIsHandedOverAgain() throws {
        RepliesSpy.reset()
        let runtime = try Self.runtime(host: true)
        let route = try #require(runtime.hostReplies)
        let profile = Self.proxied(runtime)
        var verdicts: [Bool] = []

        runtime.whenProfileProxyApplied(profile) { verdicts.append($0) }
        route.deliver(RepliesSpy.tokens[0], fields: Self.int32(0))
        route.deliver(RepliesSpy.tokens[1], fields: Self.int32(0))

        #expect(verdicts == [false])
        #expect(runtime.profileProxyChecks[profile] == nil)
        #expect(runtime.unappliedProfileProxies.contains(profile))
        runtime.whenProfileProxyApplied(profile) { verdicts.append($0) }
        #expect(RepliesSpy.proxyServers.count == 2, "the next page did not hand the proxy over again")
        route.deliver(RepliesSpy.tokens[2], fields: Self.int32(1))
        route.deliver(RepliesSpy.tokens[3], fields: Self.int32(0))
        #expect(verdicts == [false, true])
    }

    @Test func aRemoteShimWithoutTheTokenEntryPointHasNoRoute() {
        #expect(throws: CEFShimLibrary.LoadError.missingSymbol("cmux_remote_shim_last_reply_token")) {
            try CEFHostReplyRoute(symbol: { $0 == "cmux_remote_shim_last_reply_token" ? nil : RepliesSpy.symbol($0) })
        }
    }

    // MARK: Helpers

    private static func runtime(host: Bool) throws -> CEFRuntime {
        let storage = CEFProfileStorage(root: FileManager.default.temporaryDirectory
            .appending(path: "cef-host-replies-\(UUID().uuidString)", directoryHint: .isDirectory))
        let runtime = CEFRuntime(shim: try CEFShimLibrary.resolving(RepliesSpy.symbol), storage: storage)
        if host { runtime.hostReplies = try CEFHostReplyRoute(symbol: RepliesSpy.symbol) }
        return runtime
    }

    /// A profile with a proxy the shim has not taken yet.
    private static func proxied(_ runtime: CEFRuntime) -> BrowserProfileID {
        let profile = BrowserProfileID(rawValue: UUID())
        runtime.profileProxies[profile] = BrowserProfileProxy(scheme: .http, host: "proxy.test", port: 8080)
        runtime.unappliedProfileProxies.insert(profile)
        return profile
    }

    /// Lets the main actor run the task that sends, until `count` tokens are expected.
    private static func untilExpected(_ replies: CEFHostReplies, count: Int) async {
        for _ in 0..<1_000 where replies.count < count { await Task.yield() }
        #expect(replies.count == count)
    }

    /// An EncodeFields body with one int32 field (chromium_host_tlv.h: type 1, tag 0, length 4).
    private static func int32(_ value: Int32) -> [UInt8] {
        [1, 0, 4, 0] + withUnsafeBytes(of: value.littleEndian) { Array($0) }
    }
}

/// The shim's async exports for these tests: each records its call and, as the remote shim does,
/// makes the next reply token current (or none, `sendsNothing`); every other function returns 0.
private nonisolated enum RepliesSpy {
    nonisolated(unsafe) static var lastToken: UInt32 = 0
    nonisolated(unsafe) static var tokens: [UInt32] = []
    nonisolated(unsafe) static var sendsNothing = false
    nonisolated(unsafe) static var contentSettingResult: Int32 = 0
    nonisolated(unsafe) static var setProxyResult: Int32 = 1
    nonisolated(unsafe) static var proxyServers: [String] = []
    nonisolated(unsafe) static var visits = 0

    static func reset() {
        lastToken = 0
        tokens = []
        sendsNothing = false
        contentSettingResult = 0
        setProxyResult = 1
        proxyServers = []
        visits = 0
    }

    /// The remote shim's bookkeeping of one sent call (in process nobody reads it).
    static func sent() {
        guard !sendsNothing else {
            lastToken = 0
            return
        }
        lastToken = 100 + UInt32(tokens.count)
        tokens.append(lastToken)
    }

    static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        let lastReplyToken: CEFHostReplyRoute.LastReplyTokenFn = { RepliesSpy.lastToken }
        let contentSetting: @convention(c) (Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, _, _ in
            RepliesSpy.sent()
            return RepliesSpy.contentSettingResult
        }
        let visitCookies: @convention(c) (Int32, Int32) -> Int32 = { _, _ in
            RepliesSpy.visits += 1
            RepliesSpy.sent()
            return 1
        }
        let deleteCookies: @convention(c) (Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, _, _, _ in
            RepliesSpy.sent()
            return 1
        }
        let setProxy: @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, server, _ in
            RepliesSpy.proxyServers.append(server.map { String(cString: $0) } ?? "")
            RepliesSpy.sent()
            return RepliesSpy.setProxyResult
        }
        let proxyState: @convention(c) (UnsafePointer<CChar>?) -> Int32 = { _ in
            RepliesSpy.sent()
            return 0
        }
        let nothing: @convention(c) () -> Int = { 0 }
        return switch name {
        case "cmux_remote_shim_last_reply_token": unsafeBitCast(lastReplyToken, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_content_setting": unsafeBitCast(contentSetting, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_visit_cookies": unsafeBitCast(visitCookies, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_delete_cookies": unsafeBitCast(deleteCookies, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_set_context_proxy_server": unsafeBitCast(setProxy, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_context_proxy_state": unsafeBitCast(proxyState, to: UnsafeMutableRawPointer.self)
        default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
        }
    }
}
