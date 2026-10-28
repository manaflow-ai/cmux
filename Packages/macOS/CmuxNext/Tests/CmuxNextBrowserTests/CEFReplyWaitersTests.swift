import AppKit
@testable import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Darwin
import Foundation
import Testing

/// Chromium Host REPLY frames awaited by token (`CEFHostReplies` in CEFReplyWaiters.swift)
/// and read by `CEFHostReplyFields`: the golden body that
/// ChromiumHost/src/chromium_host_tlv.h's TlvWriter encodes, replies before and after the await,
/// the decode off the main thread, malformed shapes, the deadline on a manual clock, cancellation,
/// a second wait on a token, and the host's exit.
///
/// A wait registers in the turn its task first runs (every call up to the suspension is on the
/// main actor), so ``afterQueuedWork()`` returning means every wait started before it is waiting.
@MainActor @Suite(.timeLimit(.minutes(1))) struct CEFReplyWaitersTests {
    /// TlvWriter: I32(-2), Str(NULL), Str("hé"), I32Array({3, -1}), I64(0x0102030405060708),
    /// F64(1.5), StrList({"a", NULL}), Bytes(NULL), as EncodeFields writes them.
    static let golden = hexBytes(
        "01000400feffffff050100000500030068c3a90400080003000000ffffffff0200080008070605040302010300"
            + "0800000000000000f83f010004000200000005000100610501000004010000")

    nonisolated static func hexBytes(_ hex: String) -> [UInt8] {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        return bytes
    }

    /// One field as EncodeFields writes it: type, tag (1 = NULL), u16 length, payload.
    nonisolated static func field(_ type: UInt8, _ payload: [UInt8], null: Bool = false) -> [UInt8] {
        [type, null ? 1 : 0, UInt8(payload.count & 0xff), UInt8(payload.count >> 8)] + payload
    }

    nonisolated static func int32(_ value: Int32) -> [UInt8] {
        let bits = UInt32(bitPattern: value)
        return field(1, [0, 8, 16, 24].map { UInt8(truncatingIfNeeded: bits >> $0) })
    }

    nonisolated static func string(_ text: String) -> [UInt8] {
        field(5, Array(text.utf8))
    }

    /// The reply error `body` throws, nil when it returns.
    static func failure<T>(of body: () throws -> T) -> CEFHostReplyError? {
        do {
            _ = try body()
            return nil
        } catch {
            return error as? CEFHostReplyError
        }
    }

    static func awaitedFailure<T>(of body: () async throws -> T) async -> CEFHostReplyError? {
        do {
            _ = try await body()
            return nil
        } catch {
            return error as? CEFHostReplyError
        }
    }

    /// Returns after every main-actor task enqueued before it has run to its first suspension.
    static func afterQueuedWork() async {
        await Task { @MainActor in }.value
    }

    /// A wait on `token` in its own task, started now; it registers in that task's first turn.
    static func waiting(_ replies: CEFHostReplies, _ token: UInt32, timeout: Duration = .seconds(30)) -> Task<Int32, any Error> {
        Task { try await replies.reply(to: token, as: Int32.self, label: "renderer ids", timeout: timeout) }
    }

    @Test func readsTheGoldenBodyOfTheCxxWriter() throws {
        var fields = try CEFHostReplyFields(encoded: Self.golden)
        let result = try fields.int32()
        let null = try fields.string()
        let text = try fields.string()
        let ids = try fields.int32Array()
        let wide = try fields.int64()
        let real = try fields.double()
        let list = try fields.strings()
        let buffer = try fields.bytes()
        #expect(result == -2)
        #expect(null == nil)
        #expect(text == "hé")
        #expect(ids == [3, -1])
        #expect(wide == 0x0102030405060708)
        #expect(real == 1.5)
        #expect(list == ["a", ""])
        #expect(buffer.isEmpty)
        #expect(fields.isAtEnd)
        try fields.finish()
    }

    @Test func refusesBodiesThatAreNotTheReplyShape() {
        // A header past the end, a field past the end, an unknown type, a fixed field of the wrong size.
        let shortHeader = Self.failure { try CEFHostReplyFields(encoded: [1, 0, 4]) }
        let shortField = Self.failure { try CEFHostReplyFields(encoded: [1, 0, 4, 0, 1]) }
        let unknownType = Self.failure { try CEFHostReplyFields(encoded: Self.field(9, [])) }
        let wrongSize = Self.failure { try CEFHostReplyFields(encoded: Self.field(1, [1, 2, 3])) }
        // A read of the wrong type, past the end, of text that is not UTF-8, of a partial int array.
        let wrongType = Self.failure {
            var fields = try CEFHostReplyFields(encoded: Self.int32(1))
            return try fields.string()
        }
        let pastTheEnd = Self.failure {
            var fields = try CEFHostReplyFields(encoded: [])
            return try fields.int32()
        }
        let notUTF8 = Self.failure {
            var fields = try CEFHostReplyFields(encoded: Self.field(5, [0xff]))
            return try fields.string()
        }
        let partialArray = Self.failure {
            var fields = try CEFHostReplyFields(encoded: Self.field(4, [1, 2, 3, 4, 5]))
            return try fields.int32Array()
        }
        // A list longer than the fields after its count, and a field left unread.
        let longList = Self.failure {
            var fields = try CEFHostReplyFields(encoded: Self.int32(3) + Self.string("a"))
            return try fields.strings()
        }
        let leftover = Self.failure {
            var fields = try CEFHostReplyFields(encoded: Self.int32(1) + Self.int32(2))
            _ = try fields.int32()
            try fields.finish()
        }
        let all = [shortHeader, shortField, unknownType, wrongSize, wrongType, pastTheEnd, notUTF8, partialArray,
                   longList, leftover]
        #expect(all.count == 10)
        #expect(all.allSatisfy { $0 == .malformed })
    }

    @Test func keepsAReplyThatComesBeforeTheAwait() async throws {
        let replies = CEFHostReplies()
        replies.expect(7)
        #expect(replies.resolve(7, fields: Self.int32(1) + Self.string("x")))
        let value = try await replies.reply(to: 7, label: "content setting", timeout: .seconds(30)) {
            (fields: inout CEFHostReplyFields) throws(CEFHostReplyError) -> ReplyPair in
            ReplyPair(result: try fields.int32(), text: try fields.string())
        }
        #expect(value == ReplyPair(result: 1, text: "x"))
        #expect(replies.count == 0)
    }

    /// The production order: the call awaits first, the REPLY comes later and cancels the deadline.
    @Test func aReplyAfterTheAwaitResumesItsWaiterAndEndsItsDeadline() async throws {
        let clock = ManualClock()
        let replies = CEFHostReplies(clock: clock)
        replies.expect(7)
        let wait = Self.waiting(replies, 7, timeout: .seconds(5))
        try await clock.waitForSleeper()
        #expect(replies.awaiting == 1)
        #expect(replies.resolve(7, fields: Self.int32(70)))
        #expect(clock.sleeperCount == 0, "the reply left its deadline asleep")
        #expect(try await wait.value == 70)
        #expect(replies.count == 0)
    }

    @Test func decodesOffTheMainThread() async throws {
        let replies = CEFHostReplies()
        replies.expect(2)
        replies.resolve(2, fields: Self.int32(1))
        let decodedOnMain = try await replies.reply(to: 2, label: "password list", timeout: .seconds(30)) {
            (fields: inout CEFHostReplyFields) throws(CEFHostReplyError) -> Bool in
            _ = try fields.int32()
            return pthread_main_np() != 0
        }
        #expect(!decodedOnMain)
    }

    @Test func dropsATokenNobodyExpects() {
        let replies = CEFHostReplies()
        replies.expect(0)  // 0: the call sent nothing
        #expect(!replies.resolve(9, fields: Self.int32(1)))
        #expect(replies.count == 0)
    }

    @Test func eachTokenResumesItsOwnWaiterWhenRepliesComeInAnyOrder() async throws {
        let replies = CEFHostReplies()
        let tokens = (1...50).map { UInt32($0) }
        for token in tokens { replies.expect(token) }
        let waits = tokens.map { Self.waiting(replies, $0) }
        await Self.afterQueuedWork()
        #expect(replies.awaiting == 50)
        for token in tokens.reversed() { #expect(replies.resolve(token, fields: Self.int32(Int32(token) * 10))) }
        for (token, wait) in zip(tokens, waits) { #expect(try await wait.value == Int32(token) * 10) }
        #expect(replies.count == 0)
    }

    @Test func aReplyWithTheWrongShapeFailsItsWaiter() async {
        let replies = CEFHostReplies()
        replies.expect(5)
        let wait = Self.waiting(replies, 5)
        await Self.afterQueuedWork()
        replies.resolve(5, fields: Self.int32(1) + Self.int32(2))  // one value expected, two came
        #expect(await Self.awaitedFailure { try await wait.value } == .malformed)
    }

    @Test func aNullStringResultIsNil() async throws {
        let replies = CEFHostReplies()
        replies.expect(6)
        replies.resolve(6, fields: Self.field(5, [], null: true))
        let value = try await replies.reply(to: 6, as: String?.self, label: "pref get", timeout: .seconds(30))
        #expect(value == nil)
    }

    /// The deadline fires at its timeout on the injected clock, not a moment before.
    @Test func aReplyThatNeverComesTimesOutAtItsDeadline() async throws {
        let clock = ManualClock()
        let replies = CEFHostReplies(clock: clock)
        replies.expect(3)
        let wait = Task { try await replies.reply(to: 3, as: Int32.self, label: "ssl status", timeout: .seconds(5)) }
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(5) - .nanoseconds(1))
        #expect(clock.sleeperCount == 1)
        #expect(replies.awaiting == 1)
        clock.advance(by: .nanoseconds(1))
        #expect(await Self.awaitedFailure { try await wait.value } == .timedOut("ssl status", .seconds(5)))
        #expect(replies.count == 0)
        #expect(!replies.resolve(3, fields: Self.int32(1)))  // late: nobody waits any more
    }

    @Test func aCancelledWaitFailsAndLeavesNoSlot() async throws {
        let clock = ManualClock()
        let replies = CEFHostReplies(clock: clock)
        replies.expect(4)
        let waiting = Self.waiting(replies, 4)
        try await clock.waitForSleeper()
        waiting.cancel()
        #expect(await Self.awaitedFailure { try await waiting.value } == .cancelled)
        // Cancelled before its task first ran: the cancellation lands once the wait registers.
        let early = Self.waiting(replies, 4)
        early.cancel()
        #expect(await Self.awaitedFailure { try await early.value } == .cancelled)
        #expect(replies.count == 0)
        #expect(clock.sleeperCount == 0)
    }

    /// A second wait on a token takes it over, and the first fails `.superseded`. The first wait's
    /// deadline, already firing when the second registered, settles only the first wait (each wait
    /// has its own identity): the second ends at its own deadline, with its own label.
    @Test func aSupersededWaitsDeadlineLeavesTheWaitThatTookItsTokenAlone() async throws {
        let clock = ManualClock()
        let replies = CEFHostReplies(clock: clock)
        replies.expect(8)
        let first = Task { try await replies.reply(to: 8, as: Int32.self, label: "first", timeout: .seconds(1)) }
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(1))  // the first deadline fires; its settle is on its way to the main actor
        let secondsDeadline = Task {
            try await clock.waitForSleeper()
            clock.advance(by: .seconds(10))
        }
        // Registers in this turn, before the first deadline's settle can run.
        let second = await Self.awaitedFailure {
            try await replies.reply(to: 8, as: Int32.self, label: "second", timeout: .seconds(10))
        }
        #expect(second == .timedOut("second", .seconds(10)))
        #expect(await Self.awaitedFailure { try await first.value } == .superseded)
        try await secondsDeadline.value
        #expect(replies.count == 0)
    }

    @Test func theHostsExitFailsEveryTokenNotAnsweredYet() async throws {
        let replies = CEFHostReplies()
        replies.expect(1)
        replies.expect(2)
        replies.expect(3)
        replies.resolve(3, fields: Self.int32(30))  // answered before the exit: still the answer
        let waiting = Self.waiting(replies, 2)
        await Self.afterQueuedWork()
        #expect(replies.awaiting == 1)
        replies.failAll(.hostGone)
        #expect(await Self.awaitedFailure { try await waiting.value } == .hostGone)
        let first = await Self.awaitedFailure { try await replies.reply(to: 1, as: Int32.self, label: "try close", timeout: .seconds(30)) }
        #expect(first == .hostGone)
        let third = try await replies.reply(to: 3, as: Int32.self, label: "content setting", timeout: .seconds(30))
        #expect(third == 30)
        #expect(replies.count == 0)
    }

    /// How a test ends the host: the supervisor's end observers (any end, a clean exit included), or the
    /// control channel's own end under the remote shim (EOF, a malformed frame, the quota, an IO error),
    /// which may come while the host process still runs.
    nonisolated enum HostEnd: CaseIterable, Sendable {
        case observers, wireEOF
    }

    /// Task 091 (p01-process.md): when the host ends, 50 waits of every kind resolve in that turn
    /// (awaited REPLY tokens, REPLY callbacks, tokens sent and not awaited yet, evaluations, DevTools
    /// calls and site replies), and so do the latest evaluation, an extension's omnibox suggestions,
    /// a page's open question, the pane's suggestion list and an extension's prompt sheet; no
    /// continuation stays in any table, and no answer goes to the dead wire.
    @Test(arguments: HostEnd.allCases)
    func theHostsEndResolvesFiftyMixedWaitsInItsTurn(_ end: HostEnd) async throws {
        _ = NSApplication.shared
        let supervisor = EndingHost()
        // A shim of its own: this suite runs beside the ones that share HostRepliesSpy's state.
        let runtime = CEFRuntime(shim: try CEFShimLibrary.resolving(EndingHost.spy), storage: HostRepliesHarness.storage())
        // Tabs and panes hold the runtime unowned and may schedule work past the test.
        _ = Unmanaged.passRetained(runtime)
        runtime.adoptHost(supervisor)
        let host = CEFHostStart(supervisor: supervisor, open: { _ in
            do throws(CEFShimLibrary.LoadError) {
                return .success(try CEFRemoteShim.make(symbol: SpyRemoteWire.symbol(over: EndingHost.spy), expected: SpyRemoteWire.abi))
            } catch {
                return .failure(.shim(error))
            }
        })
        guard case .success = await host.attached() else { throw BrowserTabError.closed }
        runtime.hostStart = host
        let (pane, _) = HostRepliesHarness.pane(runtime, profile: .default)
        runtime.hosts[pane.key] = pane
        let tab = HostRepliesHarness.tab(in: pane)
        runtime.register(tab, browser: 1)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let page = ChromiumHostPageView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), inputTarget: .view, makeLayerHost: { _ in CALayer() })
        window.contentView?.addSubview(page)
        window.contentView?.addSubview(tab.contentView)
        pane.hostedPageView = page
        let rows = ChromiumHostSuggestionsTests.Presenter()
        page.suggestions = ChromiumHostSuggestionList(view: page, presenter: rows)

        let awaited = (1...10).map { Self.waiting(host.replies, UInt32($0)) }
        var called: [Result<[UInt8], CEFHostReplyError>] = []
        let deadlines = AlignedWakeups(queue: ReplyDeadlineRig().queue)
        for token in 11...20 {
            host.replies.onReply(UInt32(token), label: "page context", timeout: .seconds(30), deadlines: deadlines) { called.append($0) }
        }
        for token in 21...30 { host.replies.expect(UInt32(token)) }
        let evaluations = (1...7).map { token in
            Task { try await runtime.evaluations.reply(for: Int32(token), timeout: .seconds(30)) { BrowserTabError.timedOut("evaluate") } }
        }
        let devTools = (1...7).map { message in
            Task {
                try await runtime.devToolsCalls.reply(for: CEFDevToolsKey(browser: 1, message: Int32(message)), timeout: .seconds(30)) {
                    BrowserTabError.timedOut("DevTools")
                }
            }
        }
        let sites = (1...6).map { id in
            Task { try await runtime.siteReplies.reply(for: Int32(id), timeout: .seconds(30)) { BrowserTabError.timedOut("site") } }
        }
        var latest: [CEFEvaluationResult?] = []
        runtime.latestEvaluation = (token: 99, browser: 1, done: { latest.append($0) })
        var answers: [BrowserPromptResponse] = []
        tab.enqueuePrompt(.beforeUnload(isReload: false), origin: "https://example.com") { answers.append($0) }
        // An extension's suggestions: the omnibox input's REPLY (a callback) and the suggestions event (a wait).
        let keyword = Task { await runtime.omniboxKeywords.suggestions(browser: 1, extensionID: "ext", text: "q", runtime: runtime) }
        page.suggestions.handle(.show(ChromiumHostSuggestionsTests.rows()), browser: 1, wire: ChromiumHostSuggestionsTests.Recorder(browser: 1))
        // Each case its own prompt id: the dialog center is the app's one, shared with the other case.
        let promptID: Int32 = end == .observers ? 9 : 10
        runtime.extensionPrompts.arrived(promptID: promptID, browser: 1, json: #"{"type":"install","extension_id":"ext","name":"Ext"}"#)
        await Self.afterQueuedWork()
        #expect(host.replies.awaiting == 10 && host.replies.count == 31, "the omnibox input's REPLY is not awaited")
        #expect(runtime.evaluations.count + runtime.devToolsCalls.count + runtime.siteReplies.count == 20)
        #expect(rows.isShown && page.suggestions.shown != nil)
        #expect(runtime.extensionPrompts.pending.map(\.id) == [promptID],"the extension's sheet did not open")
        let sentBefore = EndingHost.wireOps.withLock { $0 }

        switch end {
        case .observers: supervisor.end()
        case .wireEOF: try SpyRemoteWire.endWire(of: host.replies)
        }

        // In the end's turn, before any waiting task runs again.
        #expect(runtime.shim == nil && runtime.state == .idle, "the dead wire stayed attached")
        #expect(called.count == 10 && called.allSatisfy { $0 == .failure(.hostGone) }, "a callback did not run with hostGone")
        #expect(host.replies.awaiting == 0, "an awaited token kept its continuation")
        #expect(runtime.evaluations.count + runtime.devToolsCalls.count + runtime.siteReplies.count == 0,
                "a wait an event answers kept its continuation")
        #expect(latest == [nil], "the latest evaluation's answer never came")
        #expect(answers.count == 1 && tab.pendingPrompts.isEmpty, "the page's question stayed open")
        #expect(!rows.isShown && page.suggestions.shown == nil, "the pane's suggestion list stayed over the page")
        #expect(runtime.extensionPrompts.pending.isEmpty, "the extension's sheet stayed open")
        #expect(!CmuxDialogCenter.shared.records.contains { $0.spec.identifier == "browser.extensionPrompt.\(promptID)" })
        #expect(EndingHost.wireOps.withLock { $0 } == sentBefore, "an answer went to the dead wire")

        var resumed = called.count
        for wait in awaited {
            if await Self.awaitedFailure(of: { try await wait.value }) == .hostGone { resumed += 1 }
        }
        for token in 21...30 {
            let failure = await Self.awaitedFailure {
                try await host.replies.reply(to: UInt32(token), as: Int32.self, label: "sent", timeout: .seconds(30))
            }
            if failure == .hostGone { resumed += 1 }
        }
        for wait in evaluations {
            if case .failure(let error as BrowserTabError) = await wait.result, error == .closed { resumed += 1 }
        }
        for wait in devTools {
            if case .failure(let error as BrowserTabError) = await wait.result, error == .closed { resumed += 1 }
        }
        for wait in sites {
            if case .failure(let error as BrowserTabError) = await wait.result, error == .closed { resumed += 1 }
        }
        #expect(resumed == 50)
        #expect(await keyword.value == nil, "the extension's suggestions waited for their deadline")
        #expect(host.replies.count == 0, "a token outlived the host")
        #expect(deadlines.pendingCount == 0, "a callback's deadline outlived the host")
        withExtendedLifetime(window) {}
    }

    /// A callback runs once, in the turn the REPLY resolves its token, and its deadline ends there.
    @Test func aCallbackRunsInTheReplysTurnAndEndsItsDeadline() {
        let rig = ReplyDeadlineRig()
        let deadlines = AlignedWakeups(queue: rig.queue)
        let replies = CEFHostReplies()
        var seen: [Result<[UInt8], CEFHostReplyError>] = []
        replies.onReply(9, label: "page context", timeout: .seconds(5), deadlines: deadlines) { seen.append($0) }
        #expect(replies.count == 1)
        #expect(deadlines.pendingCount == 1)

        #expect(replies.resolve(9, fields: Self.int32(90)))
        #expect(seen == [.success(Self.int32(90))])
        #expect(!replies.resolve(9, fields: Self.int32(91)), "a callback ran twice")
        #expect(deadlines.pendingCount == 0, "the reply left its deadline queued")
        #expect(replies.count == 0)
    }

    /// A callback whose REPLY never comes runs at its deadline on the main deadline queue, not before.
    @Test func aCallbackWithNoReplyRunsAtItsDeadline() {
        let rig = ReplyDeadlineRig()
        let replies = CEFHostReplies()
        var seen: [Result<[UInt8], CEFHostReplyError>] = []
        replies.onReply(10, label: "machine proxy state", timeout: .seconds(5), deadlines: AlignedWakeups(queue: rig.queue)) {
            seen.append($0)
        }
        rig.advance(by: .seconds(5) - .milliseconds(1))
        #expect(seen.isEmpty)
        rig.advance(by: .seconds(2))
        #expect(seen == [.failure(.timedOut("machine proxy state", .seconds(5)))])
        #expect(replies.count == 0)
        #expect(!replies.resolve(10, fields: Self.int32(1)))  // late: the callback ran
    }

    @Test func theHostsExitRunsEveryCallback() {
        let deadlines = AlignedWakeups(queue: ReplyDeadlineRig().queue)
        let replies = CEFHostReplies()
        var seen: [Result<[UInt8], CEFHostReplyError>] = []
        replies.onReply(11, label: "a", timeout: .seconds(5), deadlines: deadlines) { seen.append($0) }
        replies.onReply(12, label: "b", timeout: .seconds(5), deadlines: deadlines) { seen.append($0) }
        replies.failAll(.hostGone)
        #expect(seen == [.failure(.hostGone), .failure(.hostGone)])
        #expect(replies.count == 0)
        #expect(deadlines.pendingCount == 0)
    }
}

/// A two-value reply (a result and an out-parameter) for the typed-closure form.
private nonisolated struct ReplyPair: Equatable, Sendable {
    let result: Int32
    let text: String?
}

/// A supervisor whose ``end()`` reports the host's end to every observer, as the supervisor does for any
/// end (a clean exit included), on the main thread.
@MainActor private final class EndingHost: ChromiumHostSupervising {
    private var observers: [@MainActor () -> Void] = []

    /// The ops the spy dylib sent: `omnibox_input` (sent for a REPLY: the next token),
    /// `install_prompt_reply` and `before_unload_reply`.
    nonisolated static let wireOps = Mutex(0)
    nonisolated private static let token = Mutex<UInt32>(1_000)

    /// The spy remote dylib other than its wire entry points: the ops above and the reply token; every
    /// other symbol does nothing and returns 0.
    nonisolated static let spy: @Sendable (String) -> UnsafeMutableRawPointer? = { name in
        let omniboxInput: @convention(c) (Int32, UnsafePointer<CChar>?, Int32, UnsafePointer<CChar>?, Int32) -> Int32 = { _, _, _, _, _ in
            EndingHost.wireOps.withLock { $0 += 1 }
            EndingHost.token.withLock { $0 += 1 }
            return 1
        }
        let answer: @convention(c) (Int32, Int32) -> Int32 = { _, _ in
            EndingHost.wireOps.withLock { $0 += 1 }
            return 1
        }
        let lastReplyToken: CEFRemoteShim.LastReplyTokenFn = { EndingHost.token.withLock { $0 } }
        let nothing: @convention(c) () -> Int = { 0 }
        return switch name {
        case "cmux_shim_omnibox_input": unsafeBitCast(omniboxInput, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_install_prompt_reply", "cmux_shim_before_unload_reply": unsafeBitCast(answer, to: UnsafeMutableRawPointer.self)
        case "cmux_remote_shim_last_reply_token": unsafeBitCast(lastReplyToken, to: UnsafeMutableRawPointer.self)
        default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
        }
    }

    func attachment() async throws(ChromiumHostAttachError) -> ChromiumHostAttachment {
        ChromiumHostAttachment(controlFD: -1, remoteShim: URL(filePath: "/nonexistent/libcmux_cef_shim_remote.dylib"),
                               frameworkLocales: ["en.lproj"])
    }

    func observeHostEnds(_ ended: @escaping @MainActor () -> Void) {
        observers.append(ended)
    }

    func end() {
        for observer in observers { observer() }
    }
}
