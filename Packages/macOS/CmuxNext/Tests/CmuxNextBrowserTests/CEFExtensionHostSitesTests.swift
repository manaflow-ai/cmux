@testable import CmuxNextBrowser
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// The extension, omnibox and default-search sites in both backends (task 026 of
/// plans/cmux-next/chrome-parity/p01-process.md). A management change, the options page, load
/// unpacked and the omnibox input are async ops in the token form: their answer (Chromium's verdict)
/// comes from the call in process and in the host's REPLY in host mode. The store decides in the
/// person's turn what Chromium would refuse, shows a change at once, and takes Chromium's lists at
/// the answer, so a refused change reverts there. Host-mode cases attach a real `CEFHostStart` to the
/// spy remote dylib ``ExtensionSitesSpy`` and deliver each REPLY through the C callback the attach
/// gave it, clearing the op's pending marks first as remote_shim.mm does.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct CEFExtensionHostSitesTests {
    static let id = "abcdefghijklmnopabcdefghijklmnop"

    // MARK: The store

    /// In host mode a change makes the lists pending: it shows at once and stays while the list has
    /// no value; its REPLY takes the list the host pushed before it.
    @Test func hostModeAChangeShowsAtOnceAndItsReplyTakesTheHostsList() async throws {
        ExtensionSitesSpy.reset()
        let (runtime, _) = try await ExtensionSitesHarness.hostRuntime()
        let store = ExtensionSitesHarness.store(runtime, list: [Self.info(enabled: true)])
        let verdicts = ExtensionVerdicts()

        #expect(store.setEnabled(Self.id, false, answered: verdicts.record))

        #expect(ExtensionSitesSpy.posts == ["set_enabled \(Self.id) 0"])
        #expect(store.extensions.map(\.isEnabled) == [false], "the change did not show in the person's turn")
        var disabled = Self.info(enabled: false)
        disabled.name = "Renamed by Chromium"
        ExtensionSitesSpy.publish([disabled])
        runtime.extensionStores.refreshAll()
        #expect(store.extensions.map(\.name) == [Self.id], "a pending list was read")
        try ExtensionSitesHarness.deliver(try #require(ExtensionSitesSpy.tokens.last), CEFReplyWaitersTests.int32(1))

        #expect(verdicts.all == [true])
        #expect(store.extensions.map(\.name) == [disabled.name], "the REPLY did not take the host's list")
        #expect(store.extensions.map(\.isEnabled) == [false])
    }

    /// Before, a refused change stayed shown in host mode: Chromium raises no extension event when
    /// nothing changed, and no refresh followed the host's ack. Its REPLY of 0 now reverts it.
    @Test func hostModeARefusedChangeRevertsAtItsReply() async throws {
        ExtensionSitesSpy.reset()
        let (runtime, _) = try await ExtensionSitesHarness.hostRuntime()
        let store = ExtensionSitesHarness.store(runtime, list: [Self.info(enabled: true), Self.info(id: "other", enabled: true)])
        let verdicts = ExtensionVerdicts()

        #expect(store.setPinned(Self.id, true, answered: verdicts.record))
        #expect(store.uninstall("other", answered: verdicts.record))
        #expect(store.extensions.map(\.isPinned) == [true])
        for token in ExtensionSitesSpy.tokens { try ExtensionSitesHarness.deliver(token, CEFReplyWaitersTests.int32(0)) }

        #expect(verdicts.all == [false, false])
        #expect(store.extensions.map(\.id) == [Self.id, "other"], "a refused uninstall stayed removed")
        #expect(store.extensions.map(\.isPinned) == [false, false], "a refused pin stayed shown")
    }

    /// Before, a pending list read as no extensions: a host-mode change emptied the menus.
    @Test func hostModeAPendingListKeepsTheExtensionsShown() async throws {
        ExtensionSitesSpy.reset()
        let (runtime, _) = try await ExtensionSitesHarness.hostRuntime()
        let store = ExtensionSitesHarness.store(runtime, list: [Self.info(enabled: true), Self.info(id: "other", enabled: true)])

        #expect(store.uninstall("other"))
        runtime.extensionStores.refreshAll()

        #expect(store.extensions.map(\.id) == [Self.id], "the pending list emptied the store")
    }

    /// Before, the in-process verdict was dropped: a change Chromium refused reported success. It is
    /// the call's own answer, in the call's turn, after the store took Chromium's lists.
    @Test func inProcessAChangeAnswersChromiumsVerdictInTheCall() throws {
        ExtensionSitesSpy.reset()
        ExtensionSitesSpy.answer = 0
        let runtime = try ExtensionSitesHarness.inProcessRuntime()
        let store = ExtensionSitesHarness.store(runtime, list: [Self.info(enabled: true)])
        let verdicts = ExtensionVerdicts()

        #expect(store.setEnabled(Self.id, false, answered: verdicts.record))

        #expect(ExtensionSitesSpy.posts == ["set_enabled \(Self.id) 0"])
        #expect(verdicts.all == [false], "a refused change answered true")
        #expect(store.extensions.map(\.isEnabled) == [true], "the list Chromium kept did not win")
        ExtensionSitesSpy.answer = 1
        #expect(store.setEnabled(Self.id, false, answered: verdicts.record))
        #expect(verdicts.all == [false, true])
    }

    /// What the menus do not offer is refused in the person's turn and never sent.
    @Test func whatChromiumWouldRefuseIsNeverSent() throws {
        ExtensionSitesSpy.reset()
        let runtime = try ExtensionSitesHarness.inProcessRuntime()
        var policy = Self.info(enabled: true)
        policy.mayModify = false
        var plain = Self.info(id: "plain", enabled: false)
        plain.hasAction = false
        let store = ExtensionSitesHarness.store(runtime, list: [policy, plain], commands: [Self.command(extension: "plain")])
        let tab = try #require(runtime.tabsByBrowser[ExtensionSitesHarness.browser])

        #expect(!store.setEnabled(Self.id, false))
        #expect(!store.uninstall(Self.id))
        #expect(!store.setPinned("plain", true))
        #expect(!store.movePinned("plain", to: 0))
        #expect(!store.reload("unknown"))
        #expect(!store.openOptions("plain", from: tab), "an extension with no options page sent the op")
        #expect(!store.run(Self.command(extension: "plain"), in: tab), "a disabled extension's command ran")

        #expect(ExtensionSitesSpy.posts.isEmpty)
        #expect(ExtensionSitesSpy.tokens.isEmpty)
    }

    @Test func aRegisteredCommandRunsWithoutAnAnswer() throws {
        ExtensionSitesSpy.reset()
        let runtime = try ExtensionSitesHarness.inProcessRuntime()
        let store = ExtensionSitesHarness.store(runtime, list: [Self.info(enabled: true)], commands: [Self.command()])
        let tab = try #require(runtime.tabsByBrowser[ExtensionSitesHarness.browser])

        #expect(store.run(Self.command(), in: tab))

        #expect(ExtensionSitesSpy.posts == ["command_run \(Self.id) go"])
    }

    /// Before, any command name of an enabled extension was sent and reported as run (the CLI builds
    /// one for any name); Chrome dispatches only a command in its registered list.
    @Test func anUnregisteredCommandIsRefusedAndNotSent() throws {
        ExtensionSitesSpy.reset()
        let runtime = try ExtensionSitesHarness.inProcessRuntime()
        let store = ExtensionSitesHarness.store(runtime, list: [Self.info(enabled: true)], commands: [Self.command()])
        let tab = try #require(runtime.tabsByBrowser[ExtensionSitesHarness.browser])

        #expect(!store.run(Self.command(name: "bogus"), in: tab))

        #expect(ExtensionSitesSpy.posts.isEmpty)
    }

    // MARK: Options page and load unpacked

    @Test func inProcessTheOptionsPageAndLoadUnpackedAnswerInTheCall() throws {
        ExtensionSitesSpy.reset()
        ExtensionSitesSpy.answer = 0
        let runtime = try ExtensionSitesHarness.inProcessRuntime()
        let store = ExtensionSitesHarness.store(runtime, list: [Self.info(enabled: true)])
        let verdicts = ExtensionVerdicts()

        #expect(store.openOptions(Self.id, answered: verdicts.record))
        #expect(store.loadUnpacked(at: "/tmp/ext", answered: verdicts.record))
        ExtensionSitesSpy.answer = 1
        #expect(store.openOptions(Self.id, answered: verdicts.record))
        #expect(store.loadUnpacked(at: "/tmp/ext", answered: verdicts.record))

        #expect(verdicts.all == [false, false, true, true])
    }

    /// Before, host mode reported an options page or an unpacked load as done once sent, and only
    /// logged the host's refusal: the action told the CLI it succeeded. The REPLY is now the answer.
    @Test func hostModeTheOptionsPageAndLoadUnpackedAnswerAtTheirReplies() async throws {
        ExtensionSitesSpy.reset()
        let (runtime, host) = try await ExtensionSitesHarness.hostRuntime()
        let store = ExtensionSitesHarness.store(runtime, list: [Self.info(enabled: true)])
        let options = ExtensionVerdicts()
        let load = ExtensionVerdicts()

        #expect(store.openOptions(Self.id, answered: options.record))
        #expect(store.loadUnpacked(at: "/tmp/ext", answered: load.record))
        #expect(options.all.isEmpty && load.all.isEmpty, "an answer came before its REPLY")
        #expect(ExtensionSitesSpy.tokens.count == 2)
        #expect(host.replies.count == 2, "a sent op's token was not taken")
        try ExtensionSitesHarness.deliver(ExtensionSitesSpy.tokens[0], CEFReplyWaitersTests.int32(1))
        try ExtensionSitesHarness.deliver(ExtensionSitesSpy.tokens[1], CEFReplyWaitersTests.int32(0))

        #expect(options.all == [true])
        #expect(load.all == [false], "a host refusal did not reach the caller")
        #expect(host.replies.count == 0, "a REPLY left its token in the table")
    }

    // MARK: Omnibox

    @Test func inProcessAnExtensionThatDoesNotListenAnswersNilInTheCall() async throws {
        ExtensionSitesSpy.reset()
        ExtensionSitesSpy.answer = 0
        let runtime = try ExtensionSitesHarness.inProcessRuntime()
        let keywords = CEFOmniboxKeywords(clock: ManualClock())

        #expect(await keywords.suggestions(browser: 7, extensionID: Self.id, text: "q", runtime: runtime) == nil)
        #expect(ExtensionSitesSpy.omniboxEvents == [1])
    }

    /// Before, host mode waited out the suggestion timeout for an extension that does not listen: the
    /// remote's 1 meant only "sent". The host's REPLY of 0 ends the wait (the clock never moves here).
    @Test func hostModeAnExtensionThatDoesNotListenEndsTheWaitAtItsReply() async throws {
        ExtensionSitesSpy.reset()
        let (runtime, host) = try await ExtensionSitesHarness.hostRuntime()
        let keywords = CEFOmniboxKeywords(clock: ManualClock())

        let asked = Task { await keywords.suggestions(browser: 7, extensionID: Self.id, text: "q", runtime: runtime) }
        await CEFReplyWaitersTests.afterQueuedWork()
        #expect(ExtensionSitesSpy.omniboxEvents == [1])
        try ExtensionSitesHarness.deliver(ExtensionSitesSpy.lastToken, CEFReplyWaitersTests.int32(0))

        #expect(await asked.value == nil)
        #expect(host.replies.count == 0)
    }

    @Test func hostModeAListeningExtensionsSuggestionsArrive() async throws {
        ExtensionSitesSpy.reset()
        let (runtime, _) = try await ExtensionSitesHarness.hostRuntime()
        let keywords = CEFOmniboxKeywords(clock: ManualClock())

        let asked = Task { await keywords.suggestions(browser: 7, extensionID: Self.id, text: "q", runtime: runtime) }
        await CEFReplyWaitersTests.afterQueuedWork()
        try ExtensionSitesHarness.deliver(ExtensionSitesSpy.lastToken, CEFReplyWaitersTests.int32(1))
        keywords.suggestionsArrived(requestID: 1, extensionID: Self.id, json: #"[{"content":"a"}]"#)

        #expect(await asked.value == #"[{"content":"a"}]"#)
    }

    /// Start, enter and end need no answer, but each REPLY still settles its token.
    @Test func hostModeSessionEventsTakeTheirReplies() async throws {
        ExtensionSitesSpy.reset()
        let (runtime, host) = try await ExtensionSitesHarness.hostRuntime()
        let keywords = CEFOmniboxKeywords(clock: ManualClock())

        keywords.started(browser: 7, extensionID: Self.id, runtime: runtime)
        keywords.entered(browser: 7, extensionID: Self.id, text: "q", disposition: .newBackgroundTab, runtime: runtime)
        keywords.ended(browser: 7, extensionID: Self.id, runtime: runtime)
        #expect(ExtensionSitesSpy.omniboxEvents == [0, 2, 3])
        #expect(host.replies.count == 3)
        for token in ExtensionSitesSpy.tokens { try ExtensionSitesHarness.deliver(token, CEFReplyWaitersTests.int32(1)) }

        #expect(host.replies.count == 0, "a session event's token stayed in the table")
    }

    /// A keyword mirror with no value is not cached as "no keywords" until the next extension change.
    @Test func aKeywordMirrorWithNoValueIsReadAgain() throws {
        ExtensionSitesSpy.reset()
        let runtime = try ExtensionSitesHarness.inProcessRuntime()
        let shim = try #require(runtime.shim)
        let keywords = CEFOmniboxKeywords(clock: ManualClock())

        #expect(keywords.keywords(profile: .default, browser: 7, shim: shim).isEmpty)
        ExtensionSitesSpy.keywords = #"[{"extension_id":"\#(Self.id)","keyword":"nt","name":"Notes"}]"#

        #expect(keywords.keywords(profile: .default, browser: 7, shim: shim).map(\.keyword) == ["nt"])
    }

    // MARK: Fixtures

    static func info(id: String = CEFExtensionHostSitesTests.id, enabled: Bool) -> BrowserExtensionInfo {
        BrowserExtensionInfo(id: id, name: id, isEnabled: enabled, hasAction: true,
                             optionsURL: URL(string: "chrome-extension://\(id)/options.html"))
    }

    static func command(extension id: String = CEFExtensionHostSitesTests.id, name: String = "go") -> BrowserExtensionCommand {
        BrowserExtensionCommand(extensionID: id, name: name, keyCode: 0, modifiers: 0)
    }
}

/// The answers a change got, in order.
@MainActor final class ExtensionVerdicts {
    private(set) var all: [Bool] = []

    func record(_ accepted: Bool) {
        all.append(accepted)
    }
}

/// Runtimes for ``CEFExtensionHostSitesTests``: a Chromium tab of the default profile as browser 7,
/// in process or in host mode against ``ExtensionSitesSpy``.
@MainActor enum ExtensionSitesHarness {
    static let browser: Int32 = 7

    static func inProcessRuntime() throws -> CEFRuntime {
        let runtime = CEFRuntime(shim: try CEFShimLibrary.resolving(ExtensionSitesSpy.symbol), storage: HostRepliesHarness.storage())
        // Tabs and panes hold the runtime unowned and may schedule work past the test.
        _ = Unmanaged.passRetained(runtime)
        let (pane, _) = HostRepliesHarness.pane(runtime, profile: .default)
        runtime.register(HostRepliesHarness.tab(in: pane), browser: browser)
        return runtime
    }

    static func hostRuntime() async throws -> (CEFRuntime, CEFHostStart) {
        let runtime = try inProcessRuntime()
        let host = CEFHostStart(supervisor: OneSpyHost(), open: { _ in
            do throws(CEFShimLibrary.LoadError) { return .success(try CEFRemoteShim.make(symbol: ExtensionSitesSpy.symbol, expected: ExtensionSitesSpy.abi)) } catch {
                return .failure(.shim(error))
            }
        })
        guard case .success = await host.attached() else { throw BrowserTabError.closed }
        runtime.hostStart = host
        ExtensionSitesSpy.hostMode = true
        return (runtime, host)
    }

    /// The default profile's store over the real `CEFExtensionBackend`, showing `list`.
    static func store(_ runtime: CEFRuntime, list: [BrowserExtensionInfo], commands: [BrowserExtensionCommand] = []) -> BrowserExtensionStore {
        ExtensionSitesSpy.publish(list, commands: commands)
        let store = runtime.extensionStores.store(for: .default)
        store.refresh()
        return store
    }

    /// The host's REPLY to `token`, as remote_shim.mm hands it over: the op ran, so its pending
    /// marks clear before the reply callback.
    static func deliver(_ token: UInt32, _ fields: [UInt8]) throws {
        let sink = try #require(ExtensionSitesSpy.replySink)
        let reply = try #require(sink.reply)
        ExtensionSitesSpy.pending.remove(token)
        fields.withUnsafeBytes { reply(sink.context, token, $0.baseAddress, $0.count) }
    }
}

/// The shim and remote dylib for these tests. The lists are what Chromium (in process) or the host's
/// mirror (host mode) holds; in host mode a management op marks them pending under its token, as the
/// remote shim's MarkPending does, until ``ExtensionSitesHarness/deliver(_:_:)`` hands its REPLY over.
/// Async exports make the next token current, as PostForReply does, and answer ``answer`` (in host
/// mode the remote's own "sent" stands in). Every other function returns 0.
nonisolated enum ExtensionSitesSpy {
    static let abi = "extension-sites-spy-abi"
    // crash-allow: test-only spy state, read and written on the main thread by a serialized suite and the C stand-ins it calls there
    nonisolated(unsafe) static var lastToken: UInt32 = 0
    // crash-allow: test-only spy state (see lastToken)
    nonisolated(unsafe) static var tokens: [UInt32] = []
    // crash-allow: test-only spy state (see lastToken)
    nonisolated(unsafe) static var pending: Set<UInt32> = []
    // crash-allow: test-only spy state (see lastToken)
    nonisolated(unsafe) static var list: String?
    // crash-allow: test-only spy state (see lastToken)
    nonisolated(unsafe) static var commands = "[]"
    // crash-allow: test-only spy state (see lastToken)
    nonisolated(unsafe) static var keywords: String?
    // crash-allow: test-only spy state (see lastToken)
    nonisolated(unsafe) static var posts: [String] = []
    // crash-allow: test-only spy state (see lastToken)
    nonisolated(unsafe) static var omniboxEvents: [Int32] = []
    // crash-allow: test-only spy state (see lastToken)
    nonisolated(unsafe) static var answer: Int32 = 1
    // crash-allow: test-only spy state (see lastToken)
    nonisolated(unsafe) static var hostMode = false
    // crash-allow: test-only spy state (see lastToken)
    nonisolated(unsafe) static var replySink: (context: UnsafeMutableRawPointer?, reply: CEFRemoteShim.ReplyFn?)?
    // crash-allow: a C string made once and never freed, read only
    nonisolated(unsafe) private static let abiCString = strdup(abi)

    static func reset() {
        lastToken = 0
        tokens = []
        pending = []
        list = nil
        commands = "[]"
        keywords = nil
        posts = []
        omniboxEvents = []
        answer = 1
        hostMode = false
        replySink = nil
    }

    /// The lists Chromium holds now (in host mode: the mirror values the host pushed).
    static func publish(_ extensions: [BrowserExtensionInfo], commands registered: [BrowserExtensionCommand] = []) {
        let items = extensions.map { info -> [String: Any] in
            var item: [String: Any] = ["id": info.id, "name": info.name, "enabled": info.isEnabled, "has_action": info.hasAction,
                                       "pinned": info.isPinned, "may_modify": info.mayModify]
            if let options = info.optionsURL { item["options_url"] = options.absoluteString }
            return item
        }
        let keys = registered.map { ["extension_id": $0.extensionID, "name": $0.name, "key_code": $0.keyCode, "modifiers": $0.modifiers] as [String: Any] }
        list = String(decoding: (try? JSONSerialization.data(withJSONObject: items)) ?? Data("[]".utf8), as: UTF8.self)
        commands = String(decoding: (try? JSONSerialization.data(withJSONObject: keys)) ?? Data("[]".utf8), as: UTF8.self)
    }

    /// A management op: sent for a REPLY, its lists pending in host mode until that REPLY.
    static func manage(_ what: String) -> Int32 {
        posts.append(what)
        sent()
        guard hostMode else { return answer }
        pending.insert(lastToken)
        return 1
    }

    static func sent() {
        lastToken = 100 + UInt32(tokens.count)
        tokens.append(lastToken)
    }

    static func text(_ pointer: UnsafePointer<CChar>?) -> String {
        pointer.map { String(cString: $0) } ?? ""
    }

    static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        let abiID: @convention(c) () -> UnsafePointer<CChar>? = { UnsafePointer(ExtensionSitesSpy.abiCString) }
        let attach: CEFRemoteShim.AttachFn = { _, _, _, context, hello in
            hello?(context, 1, nil)
            return 1
        }
        let detach: CEFRemoteShim.DetachFn = {}
        let setReply: CEFRemoteShim.SetReplyFn = { context, reply in ExtensionSitesSpy.replySink = (context, reply) }
        let lastReplyToken: CEFRemoteShim.LastReplyTokenFn = { ExtensionSitesSpy.lastToken }
        let forkAPIVersion: @convention(c) () -> Int32 = { 12 }
        let extList: @convention(c) (Int32) -> UnsafeMutablePointer<CChar>? = { _ in
            ExtensionSitesSpy.pending.isEmpty ? ExtensionSitesSpy.list.flatMap { strdup($0) } : nil
        }
        let extCommands: @convention(c) (Int32) -> UnsafeMutablePointer<CChar>? = { _ in
            ExtensionSitesSpy.pending.isEmpty && ExtensionSitesSpy.list != nil ? strdup(ExtensionSitesSpy.commands) : nil
        }
        let omniboxKeywords: @convention(c) (Int32) -> UnsafeMutablePointer<CChar>? = { _ in
            ExtensionSitesSpy.keywords.flatMap { strdup($0) }
        }
        let setFlag: @convention(c) (Int32, UnsafePointer<CChar>?, Int32) -> Int32 = { _, id, value in
            ExtensionSitesSpy.manage("set_flag \(ExtensionSitesSpy.text(id)) \(value)")
        }
        let setEnabled: @convention(c) (Int32, UnsafePointer<CChar>?, Int32) -> Int32 = { _, id, value in
            ExtensionSitesSpy.manage("set_enabled \(ExtensionSitesSpy.text(id)) \(value)")
        }
        let uninstall: @convention(c) (Int32, UnsafePointer<CChar>?) -> Int32 = { _, id in
            ExtensionSitesSpy.manage("uninstall \(ExtensionSitesSpy.text(id))")
        }
        let commandRun: @convention(c) (Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, id, command in
            ExtensionSitesSpy.posts.append("command_run \(ExtensionSitesSpy.text(id)) \(ExtensionSitesSpy.text(command))")
            return 0
        }
        let asyncOp: @convention(c) (Int32, UnsafePointer<CChar>?) -> Int32 = { _, _ in
            ExtensionSitesSpy.sent()
            return ExtensionSitesSpy.hostMode ? 1 : ExtensionSitesSpy.answer
        }
        let omniboxInput: @convention(c) (Int32, UnsafePointer<CChar>?, Int32, UnsafePointer<CChar>?, Int32) -> Int32 = { _, _, event, _, _ in
            ExtensionSitesSpy.omniboxEvents.append(event)
            ExtensionSitesSpy.sent()
            return ExtensionSitesSpy.hostMode ? 1 : ExtensionSitesSpy.answer
        }
        let nothing: @convention(c) () -> Int = { 0 }
        return switch name {
        case "cmux_shim_abi_id": unsafeBitCast(abiID, to: UnsafeMutableRawPointer.self)
        case "cmux_remote_shim_attach": unsafeBitCast(attach, to: UnsafeMutableRawPointer.self)
        case "cmux_remote_shim_detach": unsafeBitCast(detach, to: UnsafeMutableRawPointer.self)
        case "cmux_remote_shim_set_reply": unsafeBitCast(setReply, to: UnsafeMutableRawPointer.self)
        case "cmux_remote_shim_last_reply_token": unsafeBitCast(lastReplyToken, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_fork_api_version": unsafeBitCast(forkAPIVersion, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_ext_list": unsafeBitCast(extList, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_ext_commands": unsafeBitCast(extCommands, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_omnibox_keywords": unsafeBitCast(omniboxKeywords, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_ext_set_enabled": unsafeBitCast(setEnabled, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_ext_set_pinned", "cmux_shim_ext_move_pinned": unsafeBitCast(setFlag, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_ext_uninstall", "cmux_shim_ext_reload": unsafeBitCast(uninstall, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_ext_command_run": unsafeBitCast(commandRun, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_ext_open_options", "cmux_shim_ext_load_unpacked": unsafeBitCast(asyncOp, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_omnibox_input": unsafeBitCast(omniboxInput, to: UnsafeMutableRawPointer.self)
        default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
        }
    }
}
