import CmuxNextCompat
@testable import CmuxNextBrowser
@testable import CmuxNextWakeups
import Foundation
import Testing

/// Host mode against a spy remote dylib, for CEFRuntimeHostRepliesTests and its pane host cases:
/// a real `CEFHostStart` attached to
/// ``HostRepliesSpy``, whose REPLY sink the tests call as the host's frames would.
@MainActor enum HostRepliesHarness {
    static func storage() -> CEFProfileStorage {
        CEFProfileStorage(root: FileManager.default.temporaryDirectory
            .appending(path: "cef-host-replies-\(UUID().uuidString)", directoryHint: .isDirectory))
    }

    static func inProcessRuntime() throws -> CEFRuntime {
        let runtime = CEFRuntime(shim: try CEFShimLibrary.resolving(HostRepliesSpy.symbol), storage: storage())
        // Tabs and panes hold the runtime unowned and may schedule work past the test.
        _ = Unmanaged.passRetained(runtime)
        return runtime
    }

    /// A runtime in host mode: a `CEFHostStart` attached to the spy remote dylib, whose REPLY sink the
    /// tests call as the host's frames would.
    static func hostRuntime() async throws -> (CEFRuntime, CEFHostStart) {
        let runtime = try inProcessRuntime()
        let host = CEFHostStart(supervisor: OneSpyHost(), open: { _ in
            do throws(CEFShimLibrary.LoadError) { return .success(try CEFRemoteShim.make(symbol: HostRepliesSpy.symbol, expected: HostRepliesSpy.abi)) } catch { return .failure(.shim(error)) }
        })
        guard case .success = await host.attached() else { throw BrowserTabError.closed }
        runtime.hostStart = host
        #expect(HostRepliesSpy.replySink?.context != nil, "the attach gave the remote shim no reply sink")
        return (runtime, host)
    }

    /// A `CEFHostStart` attached to a test's spy dylib, `symbol`, whose wire entry points are
    /// ``SpyRemoteWire``'s; `symbol` gives every other function, `cmux_remote_shim_last_reply_token`
    /// included. Async replies resolve in its ``CEFHostStart/replies``, as the attached host's do.
    static func attachedHost(over symbol: @escaping @Sendable (String) -> UnsafeMutableRawPointer?) async throws -> CEFHostStart {
        let host = CEFHostStart(supervisor: OneSpyHost(), open: { _ in
            do throws(CEFShimLibrary.LoadError) {
                return .success(try CEFRemoteShim.make(symbol: SpyRemoteWire.symbol(over: symbol), expected: SpyRemoteWire.abi))
            } catch {
                return .failure(.shim(error))
            }
        })
        guard case .success = await host.attached() else { throw BrowserTabError.closed }
        return host
    }

    /// Moves `runtime`'s main deadline queue (the callbacks' reply deadlines) onto a rig the test fires.
    static func deadlines(of runtime: CEFRuntime) -> ReplyDeadlineRig {
        let rig = ReplyDeadlineRig()
        runtime.adopt(stores: runtime.stores, signInCallbacks: runtime.signInCallbacks, waitDeadlines: rig.queue)
        return rig
    }

    /// The host's REPLY to `token`, through the remote shim's reply callback (main thread).
    static func deliver(_ token: UInt32, _ fields: [UInt8]) throws {
        let sink = try #require(HostRepliesSpy.replySink)
        let reply = try #require(sink.reply)
        fields.withUnsafeBytes { reply(sink.context, token, $0.baseAddress, $0.count) }
    }

    /// A profile with a proxy the shim has not taken yet.
    static func proxied(_ runtime: CEFRuntime) -> BrowserProfileID {
        let profile = BrowserProfileID(rawValue: UUID())
        runtime.profileProxies[profile] = BrowserProfileProxy(scheme: .http, host: "proxy.test", port: 8080)
        runtime.unappliedProfileProxies.insert(profile)
        return profile
    }

    static func pane(_ runtime: CEFRuntime, profile: BrowserProfileID) -> (CEFPaneHost, PaneEndOfTurn) {
        let pane = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: profile), runtime: runtime)
        let endOfTurn = PaneEndOfTurn()
        pane.endOfTurn = { endOfTurn.blocks.append($0) }
        return (pane, endOfTurn)
    }

    static func tab(in pane: CEFPaneHost) -> CEFTab {
        let tab = CEFTab(id: .random(), profile: pane.key.profile, host: pane, runtime: pane.runtime)
        pane.add(tab)
        return tab
    }

    static func commit(_ tab: CEFTab, _ url: String) {
        let id = tab.makeNavigationID()
        tab.machine.apply(.started(id, url: URL(string: url)))
        tab.machine.apply(.committed(id, url: URL(string: url)))
    }
}

/// The pane's end-of-turn blocks, run when the test says the turn ends.
@MainActor final class PaneEndOfTurn {
    var blocks: [@MainActor @Sendable () -> Void] = []

    func run() {
        while !blocks.isEmpty { blocks.removeFirst()() }
    }
}

/// A MainWakeUpQueue whose uptime only the test moves; ``advance(by:)`` fires it (as PageWaitersTests').
@MainActor final class ReplyDeadlineRig {
    let queue: MainWakeUpQueue
    private let uptime: ReplyTestUptime

    init() {
        let uptime = ReplyTestUptime()
        self.uptime = uptime
        queue = MainWakeUpQueue(energy: EnergyPolicySource(), ledger: WakeupLedger(uptime: { 0 }), uptime: { uptime.now }) { _ in
            ReplyIdleWakeUpTimer()
        }
    }

    func advance(by duration: Duration) {
        uptime.advance(by: duration)
        queue.fire()
    }
}

/// A timer the queue arms and parks; the rig fires the queue itself.
nonisolated final class ReplyIdleWakeUpTimer: MainWakeUpTimer {
    func arm(at date: UInt64, tolerance: UInt64, now: UInt64) {}
    func park() {}
}

/// The rig's uptime in ns: the queue reads it from any thread, only the test's main actor moves it.
nonisolated final class ReplyTestUptime: Sendable {
    private let value = Atomic<UInt64>(0)

    var now: UInt64 { value.load(ordering: .relaxed) }

    func advance(by duration: Duration) {
        value.store(now + duration.nanosecondCount, ordering: .relaxed)
    }
}

/// Hands out one wire that the spy remote takes.
@MainActor final class OneSpyHost: ChromiumHostSupervising {
    func attachment() async throws(ChromiumHostAttachError) -> ChromiumHostAttachment {
        ChromiumHostAttachment(controlFD: -1, remoteShim: URL(filePath: "/nonexistent/libcmux_cef_shim_remote.dylib"),
                               frameworkLocales: ["en.lproj"])
    }

    func observeHostEnds(_ ended: @escaping @MainActor () -> Void) {}
}

/// The remote shim's wire entry points over a test's spy dylib (``HostRepliesHarness/attachedHost(over:)``):
/// the ABI id, an attach that says hello at once, a detach, a set_reply that keeps nothing and a set_ended
/// that keeps the end callback (``endWire(of:reason:)``).
nonisolated enum SpyRemoteWire {
    static let abi = "spy-remote-wire-abi"
    // crash-allow: a C string made once and never freed, read only
    nonisolated(unsafe) private static let abiCString = strdup(abi)
    // crash-allow: test-only spy state, written and read on the main thread (the remote shim's wire entry points run there);
    // every attach hands the same C function, so a test's own reply table names its end by its token
    nonisolated(unsafe) private static var endedFn: CEFRemoteShim.EndedFn?

    /// The control channel ended under the remote shim (`reason`, a `cmux_remote_end_reason`), as its reader
    /// reports a host that closed its end: the end callback runs for `replies`, the table the attach handed it.
    @MainActor static func endWire(of replies: CEFHostReplies, reason: Int32 = 1) throws {
        let ended = try #require(endedFn, "no attach handed the remote shim an end callback")
        ended(try replies.replySinkToken().context, reason)
    }

    static func symbol(over spy: @escaping @Sendable (String) -> UnsafeMutableRawPointer?) -> @Sendable (String) -> UnsafeMutableRawPointer? {
        { name in
            let abiID: @convention(c) () -> UnsafePointer<CChar>? = { UnsafePointer(SpyRemoteWire.abiCString) }
            let attach: CEFRemoteShim.AttachFn = { _, _, _, context, hello in
                hello?(context, 1, nil)
                return 1
            }
            let detach: CEFRemoteShim.DetachFn = {}
            let setReply: CEFRemoteShim.SetReplyFn = { _, _ in }
            let setEnded: CEFRemoteShim.SetEndedFn = { _, ended in
                if let ended { SpyRemoteWire.endedFn = ended }
            }
            return switch name {
            case "cmux_shim_abi_id": unsafeBitCast(abiID, to: UnsafeMutableRawPointer.self)
            case "cmux_remote_shim_attach": unsafeBitCast(attach, to: UnsafeMutableRawPointer.self)
            case "cmux_remote_shim_detach": unsafeBitCast(detach, to: UnsafeMutableRawPointer.self)
            case "cmux_remote_shim_set_reply": unsafeBitCast(setReply, to: UnsafeMutableRawPointer.self)
            case "cmux_remote_shim_set_ended": unsafeBitCast(setEnded, to: UnsafeMutableRawPointer.self)
            default: spy(name)
            }
        }
    }
}

/// The remote dylib for these tests. Its wire entry points: attach says hello at once, set_reply keeps
/// the REPLY sink the attach hands it, last_reply_token returns the token of the last async call. Its
/// async exports record their calls and, as the remote shim's PostForReply does, make the next token
/// current (none, `sendsNothing`); `tab_add`, a mint, leaves it as it was. Every other function returns 0.
nonisolated enum HostRepliesSpy {
    static let abi = "replies-spy-abi"
    // crash-allow: test-only spy state, read and written on the main thread by a serialized suite and the C stand-ins it calls there
    nonisolated(unsafe) static var lastToken: UInt32 = 0
    // crash-allow: test-only spy state (see lastToken)
    nonisolated(unsafe) static var tokens: [UInt32] = []
    // crash-allow: test-only spy state (see lastToken)
    nonisolated(unsafe) static var sendsNothing = false
    // crash-allow: test-only spy state (see lastToken)
    nonisolated(unsafe) static var contentSettingResult: Int32 = 0
    // crash-allow: test-only spy state (see lastToken)
    nonisolated(unsafe) static var setProxyResult: Int32 = 1
    // crash-allow: test-only spy state (see lastToken)
    nonisolated(unsafe) static var proxyServers: [String] = []
    // crash-allow: test-only spy state (see lastToken)
    nonisolated(unsafe) static var visits = 0
    // crash-allow: test-only spy state (see lastToken)
    nonisolated(unsafe) static var createWindowCalls = 0
    // crash-allow: test-only spy state (see lastToken)
    nonisolated(unsafe) static var replySink: (context: UnsafeMutableRawPointer?, reply: CEFRemoteShim.ReplyFn?)?
    // crash-allow: a C string made once and never freed, read only
    nonisolated(unsafe) private static let abiCString = strdup(abi)

    static func reset() {
        lastToken = 0
        tokens = []
        sendsNothing = false
        contentSettingResult = 0
        setProxyResult = 1
        proxyServers = []
        visits = 0
        createWindowCalls = 0
        replySink = nil
    }

    /// The remote shim's bookkeeping of one sent async call (in process nobody reads it).
    static func sent() {
        guard !sendsNothing else {
            lastToken = 0
            return
        }
        lastToken = 100 + UInt32(tokens.count)
        tokens.append(lastToken)
    }

    static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        let abiID: @convention(c) () -> UnsafePointer<CChar>? = { UnsafePointer(HostRepliesSpy.abiCString) }
        let attach: CEFRemoteShim.AttachFn = { _, _, _, context, hello in
            hello?(context, 1, nil)
            return 1
        }
        let detach: CEFRemoteShim.DetachFn = {}
        let setReply: CEFRemoteShim.SetReplyFn = { context, reply in HostRepliesSpy.replySink = (context, reply) }
        let lastReplyToken: CEFRemoteShim.LastReplyTokenFn = { HostRepliesSpy.lastToken }
        let contentSetting: @convention(c) (Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, _, _ in
            HostRepliesSpy.sent()
            return HostRepliesSpy.contentSettingResult
        }
        let sslStatus: @convention(c) (Int32) -> UnsafeMutablePointer<CChar>? = { _ in
            HostRepliesSpy.sent()
            return nil
        }
        let visitCookies: @convention(c) (Int32, Int32) -> Int32 = { _, _ in
            HostRepliesSpy.visits += 1
            HostRepliesSpy.sent()
            return 1
        }
        let deleteCookies: @convention(c) (Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, _, _, _ in
            HostRepliesSpy.sent()
            return 1
        }
        let setProxy: @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, server, _ in
            HostRepliesSpy.proxyServers.append(server.map { String(cString: $0) } ?? "")
            HostRepliesSpy.sent()
            return HostRepliesSpy.setProxyResult
        }
        let proxyState: @convention(c) (UnsafePointer<CChar>?) -> Int32 = { _ in
            HostRepliesSpy.sent()
            return 0
        }
        let tabAdd: @convention(c) (Int32, UnsafePointer<CChar>?, Int32, Int32) -> Int32 = { _, _, _, _ in 1 << 30 }
        let createWindow: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?,
                                          UnsafePointer<CChar>?) -> Int32 = { _, _, _, _, _, _ in
            HostRepliesSpy.createWindowCalls += 1
            return 1
        }
        let nothing: @convention(c) () -> Int = { 0 }
        return switch name {
        case "cmux_shim_abi_id": unsafeBitCast(abiID, to: UnsafeMutableRawPointer.self)
        case "cmux_remote_shim_attach": unsafeBitCast(attach, to: UnsafeMutableRawPointer.self)
        case "cmux_remote_shim_detach": unsafeBitCast(detach, to: UnsafeMutableRawPointer.self)
        case "cmux_remote_shim_set_reply": unsafeBitCast(setReply, to: UnsafeMutableRawPointer.self)
        case "cmux_remote_shim_last_reply_token": unsafeBitCast(lastReplyToken, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_content_setting": unsafeBitCast(contentSetting, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_ssl_status": unsafeBitCast(sslStatus, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_visit_cookies": unsafeBitCast(visitCookies, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_delete_cookies": unsafeBitCast(deleteCookies, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_set_context_proxy_server": unsafeBitCast(setProxy, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_context_proxy_state": unsafeBitCast(proxyState, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_tab_add": unsafeBitCast(tabAdd, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_create_window": unsafeBitCast(createWindow, to: UnsafeMutableRawPointer.self)
        default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
        }
    }
}
