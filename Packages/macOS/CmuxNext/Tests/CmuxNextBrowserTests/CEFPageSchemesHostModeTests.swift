@testable import CmuxNextBrowser
import Darwin
import Foundation
import Testing

/// cmux-page:// first-party pages through the Chromium Host (task p01-process-070 of
/// plans/cmux-next/chrome-parity/p01-process.md). Registration is preinit: the remote shim returns its
/// own check of each call and the host's verdict comes as a REPLY, so a refusal reaches
/// ``CEFPageSchemes/add(_:through:refused:)``'s caller in the turn of that REPLY, never in the call.
/// A page's dynamic file goes back as a post, its body bounded by what one control message carries.
/// Against a spy remote dylib attached through a real `CEFHostStart`.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct CEFPageSchemesHostModeTests {
    private static let root = URL(fileURLWithPath: "/Applications/cmux.app/Contents/Resources/pages/x")

    private static let table: [String: CEFPageSchemes.Entry] = [
        "cmux.agent": CEFPageSchemes.Entry(root: root, csp: "default-src 'self'", processGroup: "agent"),
        "cmux.diff": CEFPageSchemes.Entry(root: root, csp: "default-src 'self'", dynamicPrefixes: ["__patch"],
                                          entry: "diff-page.html"),
        "cmux.settings": CEFPageSchemes.Entry(root: root, csp: "default-src 'self'"),
    ]

    @Test func aRefusalComesWithTheHostsReply() async throws {
        let (runtime, host) = try await Self.hostRuntime()
        var refused: [CEFPageSchemes.Refusal] = []

        CEFPageSchemes.add(Self.table, through: runtime) { refused.append($0) }
        #expect(refused.isEmpty, "a refusal came before any REPLY: \(refused)")
        #expect(PageSchemeHostSpy.calls == ["page cmux.agent", "dynamic cmux.diff", "page cmux.settings", "group cmux.agent agent"])
        #expect(host.replies.count == 4, "every preinit call waits for its verdict")

        host.replies.resolve(try #require(PageSchemeHostSpy.tokens["cmux.agent"]), fields: CEFReplyWaitersTests.int32(1))
        host.replies.resolve(try #require(PageSchemeHostSpy.tokens["cmux.diff"]), fields: CEFReplyWaitersTests.int32(0))
        #expect(refused == [.page("cmux.diff")])
        host.replies.resolve(try #require(PageSchemeHostSpy.tokens["group cmux.agent"]), fields: CEFReplyWaitersTests.int32(0))
        host.replies.resolve(try #require(PageSchemeHostSpy.tokens["cmux.settings"]), fields: CEFReplyWaitersTests.int32(1))

        #expect(refused == [.page("cmux.diff"), .group("cmux.agent")])
        #expect(host.replies.count == 0)
    }

    /// The remote shim's own check (the in-process shim's refusals that need no Chromium) sends nothing
    /// and makes no token current: a refusal in the call, as in process.
    @Test func theClientsOwnRefusalIsReportedInTheCall() async throws {
        let (runtime, host) = try await Self.hostRuntime()
        PageSchemeHostSpy.clientRefuses = ["cmux.settings"]
        var refused: [CEFPageSchemes.Refusal] = []

        CEFPageSchemes.add(Self.table, through: runtime) { refused.append($0) }

        #expect(refused == [.page("cmux.settings")])
        #expect(PageSchemeHostSpy.tokens["cmux.settings"] == nil)
        #expect(host.replies.count == 3)
    }

    /// No verdict by the deadline, or a host that exited first, says nothing of the call: the host may
    /// have applied it, and the next host applies it from the replay log.
    @Test func aPassedDeadlineOrAnExitedHostIsNoRefusal() async throws {
        let (runtime, host) = try await Self.hostRuntime()
        let rig = HostRepliesHarness.deadlines(of: runtime)
        var refused: [CEFPageSchemes.Refusal] = []

        CEFPageSchemes.add(Self.table, through: runtime) { refused.append($0) }
        host.replies.resolve(try #require(PageSchemeHostSpy.tokens["cmux.agent"]), fields: CEFReplyWaitersTests.int32(1))
        rig.advance(by: CEFRuntime.siteReplyTimeout + .seconds(1))
        #expect(refused.isEmpty, "\(refused)")
        #expect(host.replies.count == 0)

        CEFPageSchemes.add(Self.table, through: runtime) { refused.append($0) }
        runtime.hostGone()
        #expect(refused.isEmpty, "\(refused)")
        #expect(host.replies.count == 0)
    }

    /// A dynamic file goes back whole in host mode (the channel moves a body past 64 KiB into shared
    /// memory); past what one control message carries it becomes a 500 with no body, so the request
    /// ends instead of waiting for an answer the wire would drop. In process nothing bounds it.
    @Test func aDynamicFileTheWireCannotCarryEndsTheRequest() async throws {
        let (runtime, _) = try await Self.hostRuntime()
        let (pane, _) = HostRepliesHarness.pane(runtime, profile: .default)
        let tab = HostRepliesHarness.tab(in: pane)
        let big = Data(count: 10 * 1024 * 1024)
        tab.pageResources = { _ in CEFPageResponse(status: 200, mimeType: "text/x-diff", body: big) }

        runtime.answerPageResource(token: 7, url: "cmux-page://cmux.diff/__patch/a", tab: tab)
        try await Self.untilAnswered(1)
        #expect(PageSchemeHostSpy.answers.last == .init(token: 7, status: 200, mime: "text/x-diff", length: big.count))

        let tooBig = Data(count: CEFPageResponse.hostBodyLimit + 1)
        tab.pageResources = { _ in CEFPageResponse(status: 200, mimeType: "text/x-diff", body: tooBig) }
        runtime.answerPageResource(token: 8, url: "cmux-page://cmux.diff/__patch/b", tab: tab)
        try await Self.untilAnswered(2)
        #expect(PageSchemeHostSpy.answers.last == .init(token: 8, status: 500, mime: "text/plain", length: 0))
    }

    /// An answer still being made when its host ends never reaches the next host: that host's tokens
    /// count from 1 again, so the old answer would end another page's request with this page's file.
    @Test func anAnswerMadeForAnEndedHostNeverReachesTheNextHost() async throws {
        let (runtime, host) = try await Self.hostRuntime()
        let (pane, _) = HostRepliesHarness.pane(runtime, profile: .default)
        let tab = HostRepliesHarness.tab(in: pane)
        let pending = PendingPageResource()
        tab.pageResources = { _ in await pending.response() }
        runtime.state = .ready

        runtime.answerPageResource(token: 1, url: "cmux-page://cmux.diff/__patch/a", tab: tab)
        try await pending.untilAsked()
        runtime.hostEnded(BrowserProcessExit(reason: .killed, code: Int(SIGKILL), engine: .cef))
        guard case .success = await host.attached() else { throw BrowserTabError.closed }
        runtime.shim = try CEFShimLibrary.resolving(PageSchemeHostSpy.symbol)
        runtime.state = .ready
        pending.answer(CEFPageResponse(status: 200, mimeType: "text/x-diff", body: Data([1, 2, 3])))
        for _ in 0..<10 { await CEFReplyWaitersTests.afterQueuedWork() }

        #expect(PageSchemeHostSpy.answers.isEmpty, "the ended host's answer reached the next host: \(PageSchemeHostSpy.answers)")
    }

    @Test func theBodyLimitIsTheWires() {
        let small = CEFPageResponse(status: 200, mimeType: "text/html", body: Data([1, 2, 3]))
        #expect(small.fittingHostWire == small)
        #if DEBUG || CMUX_BENCH_HOOKS
        #expect(CEFPageResponse.hostBodyLimit == ChromiumHostSharedRegion.maxBytes)
        #endif
    }

    /// A runtime over the spy, in host mode: its `CEFHostStart` is attached to the same spy, whose
    /// REPLYs the tests resolve in the start's table.
    private static func hostRuntime() async throws -> (CEFRuntime, CEFHostStart) {
        PageSchemeHostSpy.reset()
        let runtime = CEFRuntime(shim: try CEFShimLibrary.resolving(PageSchemeHostSpy.symbol), storage: HostRepliesHarness.storage())
        // Tabs and panes hold the runtime unowned and may schedule work past the test.
        _ = Unmanaged.passRetained(runtime)
        let host = try await HostRepliesHarness.attachedHost(over: { PageSchemeHostSpy.symbol($0) })
        runtime.hostStart = host
        return (runtime, host)
    }

    /// Lets the answer's task run until the spy has `count` answers.
    private static func untilAnswered(_ count: Int) async throws {
        for _ in 0..<100 where PageSchemeHostSpy.answers.count < count {
            await CEFReplyWaitersTests.afterQueuedWork()
        }
        try #require(PageSchemeHostSpy.answers.count == count)
    }
}

/// A page's dynamic file the test answers when it chooses (``answer(_:)``), after its request was made.
@MainActor final class PendingPageResource {
    private var waiting: CheckedContinuation<CEFPageResponse, Never>?

    func response() async -> CEFPageResponse {
        await withCheckedContinuation { waiting = $0 }
    }

    /// Lets queued work run until the page's request waits for its answer.
    func untilAsked() async throws {
        for _ in 0..<100 where waiting == nil {
            await CEFReplyWaitersTests.afterQueuedWork()
        }
        try #require(waiting != nil)
    }

    func answer(_ response: CEFPageResponse) {
        waiting?.resume(returning: response)
        waiting = nil
    }
}

/// The remote dylib's page exports as the remote shim answers them. A page or group add is a preinit
/// with a verdict (PostPreinit): 0 for an id the client's own check refuses, which sends nothing and
/// makes no token current; else 1, with the call's token current until the host's REPLY. A page
/// resource answer is a post, recorded. Every other function returns 0.
nonisolated enum PageSchemeHostSpy {
    struct Answer: Equatable {
        var token: Int32
        var status: Int32
        var mime: String
        var length: Int
    }

    // crash-allow: test-only spy state, read and written on the main thread by a serialized suite and the C stand-ins it calls there
    nonisolated(unsafe) static var lastToken: UInt32 = 0
    // crash-allow: test-only spy state (see lastToken)
    nonisolated(unsafe) static var calls: [String] = []
    // crash-allow: test-only spy state (see lastToken)
    nonisolated(unsafe) static var tokens: [String: UInt32] = [:]
    // crash-allow: test-only spy state (see lastToken)
    nonisolated(unsafe) static var clientRefuses: Set<String> = []
    // crash-allow: test-only spy state (see lastToken)
    nonisolated(unsafe) static var answers: [Answer] = []

    static func reset() {
        lastToken = 0
        calls = []
        tokens = [:]
        clientRefuses = []
        answers = []
    }

    /// One preinit call: the client's check, then the token the host's verdict answers.
    static func preinit(_ call: String, key: String, id: String) -> Int32 {
        calls.append(call)
        guard !clientRefuses.contains(id) else {
            lastToken = 0
            return 0
        }
        lastToken = 200 + UInt32(calls.count)
        tokens[key] = lastToken
        return 1
    }

    static func text(_ pointer: UnsafePointer<CChar>?) -> String { pointer.map { String(cString: $0) } ?? "" }

    static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        let lastReplyToken: CEFRemoteShim.LastReplyTokenFn = { PageSchemeHostSpy.lastToken }
        let add: @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { id, _, _ in
            let id = PageSchemeHostSpy.text(id)
            return PageSchemeHostSpy.preinit("page \(id)", key: id, id: id)
        }
        let addDynamic: @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?,
                                        UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { id, _, _, _, _ in
            let id = PageSchemeHostSpy.text(id)
            return PageSchemeHostSpy.preinit("dynamic \(id)", key: id, id: id)
        }
        let setGroup: @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { id, group in
            let id = PageSchemeHostSpy.text(id)
            return PageSchemeHostSpy.preinit("group \(id) \(PageSchemeHostSpy.text(group))", key: "group \(id)", id: id)
        }
        let respond: @convention(c) (Int32, Int32, UnsafePointer<CChar>?, UnsafeRawPointer?, Int) -> Int32 = { token, status, mime, _, length in
            PageSchemeHostSpy.answers.append(Answer(token: token, status: status, mime: PageSchemeHostSpy.text(mime), length: length))
            return 1
        }
        let nothing: @convention(c) () -> Int = { 0 }
        return switch name {
        case "cmux_remote_shim_last_reply_token": unsafeBitCast(lastReplyToken, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_page_scheme_add_first_party": unsafeBitCast(add, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_page_scheme_add_first_party_dynamic": unsafeBitCast(addDynamic, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_page_scheme_set_group": unsafeBitCast(setGroup, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_page_resource_respond": unsafeBitCast(respond, to: UnsafeMutableRawPointer.self)
        default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
        }
    }
}
