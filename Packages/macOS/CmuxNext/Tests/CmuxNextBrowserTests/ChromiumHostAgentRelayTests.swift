@testable import CmuxNextBrowser
import CmuxNextCompat
import Darwin
import Foundation
import Testing

/// The supervisor hands each Chromium Host the browser host's relay link
/// (``ChromiumHostAgentRelaying``). The host start observes it: a link known before the attach reaches the
/// remote shim once at that attach, a later change reaches it at once, and the next host after a host end
/// gets it again at its own attach. A page is named to the browser host (``CEFAgentRelay/directTarget``)
/// only while an attached host that relays agents and a link are both there. Against a spy remote shim and
/// a fake supervisor; task 080's `ChromiumHostSupervisor` must adopt ``ChromiumHostAgentRelaying`` the same way.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct ChromiumHostAgentRelayTests {
    private static let link = ChromiumHostRelayLink(socketPath: "/tmp/bh/browser-host-provider.sock", credential: "cred",
                                                    linkID: "link_a", hostPID: 10, listenerPID: 11)
    private static let other = ChromiumHostRelayLink(socketPath: "/tmp/bh/browser-host-provider.sock", credential: "cred-2",
                                                     linkID: "link_b", hostPID: 12, listenerPID: 0)

    @Test func aLinkKnownBeforeTheAttachReachesTheShimOnceAtTheAttach() async throws {
        let (start, supervisor) = Self.hostStart()
        supervisor.agentRelay.setRelayLink(Self.link)
        #expect(RelayWire.sent().isEmpty, "the link went to a shim no host is attached to")

        _ = try Self.attached(await start.attached())
        _ = try Self.attached(await start.attached())

        #expect(RelayWire.sent() == [.link("link_a", socket: Self.link.socketPath)], "one attach, one link")
        #expect(start.relaysAgents)
    }

    @Test func aLinkChangeAfterTheAttachReachesTheShimAtOnce() async throws {
        let (start, supervisor) = Self.hostStart()
        _ = try Self.attached(await start.attached())
        #expect(RelayWire.sent().isEmpty)

        supervisor.agentRelay.setRelayLink(Self.link)
        supervisor.agentRelay.setRelayLink(Self.link)
        supervisor.agentRelay.setRelayLink(Self.other)
        supervisor.agentRelay.setRelayLink(nil)

        #expect(RelayWire.sent() == [.link("link_a", socket: Self.link.socketPath),
                                     .link("link_b", socket: Self.other.socketPath), .end],
                "a repeated link went again, or a change did not go")
    }

    @Test func theNextHostAfterAHostEndGetsTheLinkAtItsOwnAttach() async throws {
        let (start, supervisor) = Self.hostStart()
        supervisor.agentRelay.setRelayLink(Self.link)
        _ = try Self.attached(await start.attached())
        start.hostEnded()
        #expect(!start.relaysAgents && start.hostGone)

        _ = try Self.attached(await start.attached())

        #expect(supervisor.asked == 2)
        #expect(RelayWire.sent() == [.link("link_a", socket: Self.link.socketPath),
                                     .link("link_a", socket: Self.link.socketPath)], "the next host has no link")
    }

    @Test func aPageIsNamedOnlyWithARelayingHostAndALink() async throws {
        let (runtime, start, supervisor) = try await Self.startedRuntime()
        let tab = Self.tab(runtime, browser: 7)
        #expect(tab.agentRelay.directTarget == nil, "a page was named with no link")

        supervisor.agentRelay.setRelayLink(Self.link)
        #expect(tab.agentRelay.directTarget == CEFAgentDirectTarget(browser: 7, linkID: "link_a"))

        start.hostEnded()
        #expect(tab.agentRelay.directTarget == nil, "a page of a host that ended was named")
    }

    @Test func aHostThatCannotRelayNamesNoPage() async throws {
        let (runtime, _, supervisor) = try await Self.startedRuntime(relays: false)
        let tab = Self.tab(runtime, browser: 7)
        supervisor.agentRelay.setRelayLink(Self.link)

        #expect(tab.agentRelay.directTarget == nil, "a page was named on a host whose HELLO lists no provider link")
    }

    // MARK: Fixtures

    private static func hostStart(relays: Bool = true) -> (CEFHostStart, RelayingHost) {
        RelayWire.reset(relays: relays)
        let supervisor = RelayingHost()
        let start = CEFHostStart(supervisor: supervisor, open: { _ in
            do throws(CEFShimLibrary.LoadError) {
                return .success(try CEFRemoteShim.make(symbol: RelayWire.symbol, expected: RelayWire.abi))
            } catch {
                return .failure(.shim(error))
            }
        })
        return (start, supervisor)
    }

    private static func attached(_ outcome: Result<CEFAttachedHost, CEFRuntime.BootError>) throws -> CEFAttachedHost {
        try outcome.get()
    }

    /// A runtime started in host mode over the spy shim. It outlives the test: a pane's scheduled work reads
    /// it through an unowned reference.
    private static func startedRuntime(relays: Bool = true) async throws -> (CEFRuntime, CEFHostStart, RelayingHost) {
        let (start, supervisor) = hostStart(relays: relays)
        let root = FileManager.default.temporaryDirectory.appending(path: "cef-agent-relay-\(UUID().uuidString)",
                                                                     directoryHint: .isDirectory)
        let runtime = CEFRuntime(storage: CEFProfileStorage(root: root))
        runtime.loadInProcess = { _ in .failure(.notEmbedded) }
        runtime.adoptHost(supervisor)
        runtime.hostStart = start
        try await runtime.start(layout: nil, environment: [:], trigger: "test")
        _ = Unmanaged.passRetained(runtime)
        return (runtime, start, supervisor)
    }

    /// A tab in a pane of its own whose browser is `browser`.
    private static func tab(_ runtime: CEFRuntime, browser: Int32) -> CEFTab {
        let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
        host.endOfTurn = { $0() }
        let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(tab)
        runtime.register(tab, browser: browser)
        return tab
    }
}

/// A supervisor whose hosts take the relay link: hands out the read end of one pipe as the wire on each
/// request (the spy shim never reads it). Its conformance is main-actor isolated, as its inherited
/// ``ChromiumHostSupervising`` one is; the host start and the browser host cast to it on the main actor.
@MainActor private final class RelayingHost: @MainActor ChromiumHostAgentRelaying {
    let agentRelay = ChromiumHostAgentRelay()
    private(set) var asked = 0
    private lazy var wire: Int32 = {
        var fds: [Int32] = [-1, -1]
        return Darwin.pipe(&fds) == 0 ? fds[0] : -1
    }()

    func attachment() async throws(ChromiumHostAttachError) -> ChromiumHostAttachment {
        asked += 1
        guard wire >= 0 else { throw .cannotStart("no pipe for the wire") }
        return ChromiumHostAttachment(controlFD: wire, remoteShim: URL(filePath: "/nonexistent/libcmux_cef_shim_remote.dylib"),
                                      frameworkLocales: ["en.lproj"])
    }

    func observeHostEnds(_ ended: @escaping @MainActor () -> Void) {}
}

/// The remote dylib: the ABI id; attach (says hello at once, listing the provider link export when the host
/// relays agents); detach; the reply token; initialize (succeeds); and `cmux_remote_shim_set_provider_link`,
/// recorded. Every other export does nothing and returns 0.
private nonisolated enum RelayWire {
    private static let abiCString: StaticString = "agent-relay-spy-abi"
    private static let exportsCString: StaticString = "cmux_host_provider_link"
    static let abi = "\(abiCString)"

    /// One `cmux_remote_shim_set_provider_link` call.
    enum Sent: Equatable {
        case link(String, socket: String)
        case end
    }

    struct State {
        var relays = true
        var sent: [Sent] = []
    }

    static let state = Mutex(State())

    static func reset(relays: Bool) {
        state.withLock { $0 = State(relays: relays) }
    }

    static func sent() -> [Sent] {
        state.withLock { $0.sent }
    }

    static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        let abiID: @convention(c) () -> UnsafePointer<CChar>? = {
            UnsafeRawPointer(RelayWire.abiCString.utf8Start).assumingMemoryBound(to: CChar.self)
        }
        let attach: CEFRemoteShim.AttachFn = { _, _, _, context, hello in
            let relays = RelayWire.state.withLock { $0.relays }
            let exports: UnsafePointer<CChar>? = if relays {
                UnsafeRawPointer(RelayWire.exportsCString.utf8Start).assumingMemoryBound(to: CChar.self)
            } else {
                nil
            }
            hello?(context, 1, exports)
            return 1
        }
        let detach: CEFRemoteShim.DetachFn = {}
        let setReply: CEFRemoteShim.SetReplyFn = { _, _ in }
        let lastReplyToken: CEFRemoteShim.LastReplyTokenFn = { 0 }
        let initialize: @convention(c) (
            UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?,
            UnsafePointer<CChar>?, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?,
            UnsafePointer<UnsafePointer<CChar>?>?,
            UnsafeMutableRawPointer?, CEFShimLibrary.ScheduleFn?, CEFShimLibrary.EventFn?, CEFShimLibrary.KeyFn?
        ) -> Int32 = { _, _, _, _, _, _, _, _, _, _, _, _, _ in 1 }
        let setProviderLink: CEFRemoteShim.SetProviderLinkFn = { socket, _, linkID, _, _ in
            let sent: Sent = if let socket, let linkID {
                .link(String(cString: linkID), socket: String(cString: socket))
            } else {
                .end
            }
            RelayWire.state.withLock { $0.sent.append(sent) }
            return 1
        }
        let nothing: @convention(c) () -> Int = { 0 }
        return switch name {
        case "cmux_shim_abi_id": unsafeBitCast(abiID, to: UnsafeMutableRawPointer.self)
        case "cmux_remote_shim_attach": unsafeBitCast(attach, to: UnsafeMutableRawPointer.self)
        case "cmux_remote_shim_detach": unsafeBitCast(detach, to: UnsafeMutableRawPointer.self)
        case "cmux_remote_shim_set_reply": unsafeBitCast(setReply, to: UnsafeMutableRawPointer.self)
        case "cmux_remote_shim_last_reply_token": unsafeBitCast(lastReplyToken, to: UnsafeMutableRawPointer.self)
        case "cmux_remote_shim_set_provider_link": unsafeBitCast(setProviderLink, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_initialize": unsafeBitCast(initialize, to: UnsafeMutableRawPointer.self)
        default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
        }
    }
}
