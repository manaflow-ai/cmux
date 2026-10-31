import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The Needs you list reads each chat's open permission requests through the page's own op
/// (`cmux.agent.chat.asks.pending`), never the relay: the relay refuses `_acpmux/info`, so a read
/// sent there never lands and answered asks stay listed (PR #22646 review). The op must stay on
/// the page's op list, read only the pane's own acpmux (a Chief pane's is the Chief home's daemon,
/// not this app's main one), and hand back only the fields the pane's watch already carries.
@Suite(.serialized)
@MainActor
struct AgentPanePendingAsksTests {
    /// This app's main acpmux and a Chief home's own (`ChiefHomeAcpmux`, its own `ACPMUX_HOME`).
    static let mainSocket = "/tmp/acpmux-main.sock"
    static let chiefSocket = "/tmp/acpmux-chief.sock"

    /// Fake daemons by socket: each holds its own sessions' open requests and the peer chats it
    /// mirrors (an SSH or Cloud peer's, listed in its watch with `peer`), and records every read.
    /// It resolves a key as acpmux does (hub `resolve`, then server/peer_forward.rs): `local/<id>`
    /// names this daemon's own session; a bare id that is not its own but a peer's is forwarded
    /// to that peer, whose reply comes back marked with the peer's name (`peer`). `localPeer`: a
    /// peer that happens to be named `local`, whose rows acpmux keys `local/<id>`, so a
    /// `local/<id>` that is not the daemon's own is forwarded there.
    @MainActor final class Daemons {
        var pending: [String: [String: [[String: Any]]]] = [:]
        var mirrored: [String: [String: [[String: Any]]]] = [:]
        var localPeer: [String: [String: [[String: Any]]]] = [:]
        var reads: [(socket: String, session: String)] = []

        var reader: AgentPanePendingAsks {
            AgentPanePendingAsks { [self] socket, key in
                reads.append((socket, key))
                let local = key.hasPrefix("local/") ? String(key.dropFirst("local/".count)) : nil
                if let own = pending[socket]?[local ?? key] { return ["sessionId": local ?? key, "pending": own] }
                // Not its own: forwarded to the peer that lists it, and marked with that peer.
                if let local, let entries = localPeer[socket]?[local] {
                    return ["sessionId": local, "pending": entries, "peer": "local"]
                }
                if local == nil, let entries = mirrored[socket]?[key] {
                    return ["sessionId": key, "pending": entries, "peer": "build-host"]
                }
                return nil  // not_found on that daemon
            }
        }

        func sockets() -> [String] { reads.map { $0.socket } }
    }

    static let context = PageCallContext(page: PageDescriptor.agent.id)

    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// A pane whose last handshake connected it to the acpmux at `socket` (nil: none yet).
    static func pane(socket: String?) -> AgentPaneModel {
        let model = AgentPaneModel(host: NoHost())
        model.transport.acpmuxSocket = socket
        return model
    }

    /// The op from a pane wired as ``AgentPaneView`` wires it.
    static func call(_ params: [String: JSONValue], model: AgentPaneModel, daemons: Daemons) async throws -> JSONValue {
        let provider = AgentPageProvider { _ in nil }
        provider.pendingAsks = daemons.reader
        provider.pendingAsksSocket = { [weak model] in model?.pendingAsksSocket }
        return try await provider.call(AgentPageOps.namespace + "chat.asks.pending", params: .object(params), context: context)
    }

    static func permissionIds(_ reply: JSONValue) -> [String]? {
        guard case .object(let body) = reply, case .array(let entries)? = body["pending"] else { return nil }
        return entries.compactMap { entry in
            guard case .object(let fields) = entry, case .string(let id)? = fields["permissionId"] else { return nil }
            return id
        }
    }

    @Test func thePageReadsAChatsOpenAsksThroughTheHostNotTheRelay() async throws {
        #expect(AgentPageOps.all.contains("cmux.agent.chat.asks.pending"))
        // The relay refuses this read: that is why the host serves it.
        #expect(!AcpmuxPaneMethods.requests.contains("_acpmux/info"))

        let daemons = Daemons()
        let request: [String: Any] = ["toolCall": ["title": "Run npm test"]]
        daemons.pending[Self.mainSocket] = ["s-1": [["permissionId": "p1", "request": request, "turnId": "t1", "groupId": NSNull(),
                                                     "answeredBy": "x", "secret": "kept on the host"]]]

        let reply = try await Self.call(["sessionId": .string("s-1")], model: Self.pane(socket: Self.mainSocket), daemons: daemons)
        #expect(daemons.reads.map { $0.session } == ["local/s-1"])
        #expect(daemons.sockets() == [Self.mainSocket])
        guard case .object(let body) = reply, case .array(let entries)? = body["pending"],
              case .object(let entry)? = entries.first else {
            Issue.record("expected {pending: [entry]}, got \(reply)")
            return
        }
        #expect(Set(entry.keys) == ["permissionId", "request", "turnId", "groupId"])
        #expect(entry["permissionId"] == .string("p1"))
        #expect(entry["turnId"] == .string("t1"))
    }

    /// A Chief pane (`.chief` tab, or a `.local` tab the Chief session router sent to the Chief
    /// home) reads the Chief home's daemon and only it: a chat that lives on this app's main
    /// acpmux, or a peer's chat mirrored there, is not visible from it (PR #22646 review).
    @Test func aChiefPaneReadsOnlyItsOwnDaemon() async throws {
        let daemons = Daemons()
        daemons.pending[Self.chiefSocket] = ["chief-chat": [["permissionId": "c1"]]]
        daemons.pending[Self.mainSocket] = ["main-chat": [["permissionId": "m1"]]]
        daemons.mirrored[Self.mainSocket] = ["peer-mirror": [["permissionId": "x1"]]]
        daemons.mirrored[Self.chiefSocket] = ["peer-mirror": [["permissionId": "x1"]]]
        let chief = Self.pane(socket: Self.chiefSocket)

        let own = try await Self.call(["sessionId": .string("chief-chat")], model: chief, daemons: daemons)
        #expect(Self.permissionIds(own) == ["c1"])
        #expect(try await Self.call(["sessionId": .string("main-chat")], model: chief, daemons: daemons) == .null)
        #expect(try await Self.call(["sessionId": .string("peer-mirror")], model: chief, daemons: daemons) == .null)
        #expect(daemons.sockets() == [Self.chiefSocket, Self.chiefSocket, Self.chiefSocket])
        #expect(!daemons.sockets().contains(Self.mainSocket))
    }

    /// An ask answered in a Chief chat leaves: the reread through the Chief daemon returns the
    /// smaller set (the page replaces the chat's asks with it, webviews
    /// `agent-pane-needs-you-asks.test.ts`), where a read of the main daemon answered null and the
    /// page kept the answered ask.
    @Test func anAskAnsweredInAChiefChatDropsOffOnTheReread() async throws {
        let daemons = Daemons()
        daemons.pending[Self.chiefSocket] = ["chief-chat": [["permissionId": "c1"], ["permissionId": "c2"]]]
        let chief = Self.pane(socket: Self.chiefSocket)

        let before = try await Self.call(["sessionId": .string("chief-chat")], model: chief, daemons: daemons)
        #expect(Self.permissionIds(before) == ["c1", "c2"])
        daemons.pending[Self.chiefSocket]?["chief-chat"] = [["permissionId": "c2"]]  // c1 answered
        let after = try await Self.call(["sessionId": .string("chief-chat")], model: chief, daemons: daemons)
        #expect(Self.permissionIds(after) == ["c2"])
        daemons.pending[Self.chiefSocket]?["chief-chat"] = []  // c2 answered too
        let cleared = try await Self.call(["sessionId": .string("chief-chat")], model: chief, daemons: daemons)
        #expect(Self.permissionIds(cleared) == [])
        #expect(daemons.sockets() == [Self.chiefSocket, Self.chiefSocket, Self.chiefSocket])
    }

    /// A chat on another computer is listed by the pane's daemon with its `peer` (acpmux
    /// hub/peers.rs), and a read naming it by its bare id is forwarded to that computer's daemon
    /// (server/peer_forward.rs). The host names the chat `local/<id>`, which acpmux resolves on its
    /// own sessions only, so a peer's asks are never read, let alone drawn with Allow and Deny
    /// (PR #22646 review). An id already qualified as local is sent as it is; one qualified with
    /// another host is never sent.
    @Test func aPeersChatMirroredInThePanesDaemonIsNeverRead() async throws {
        let daemons = Daemons()
        daemons.pending[Self.mainSocket] = ["own": [["permissionId": "o1"]]]
        daemons.mirrored[Self.mainSocket] = ["peer-chat": [["permissionId": "x1"]]]
        let pane = Self.pane(socket: Self.mainSocket)

        #expect(try await Self.call(["sessionId": .string("peer-chat")], model: pane, daemons: daemons) == .null)
        #expect(Self.permissionIds(try await Self.call(["sessionId": .string("own")], model: pane, daemons: daemons)) == ["o1"])
        #expect(Self.permissionIds(try await Self.call(["sessionId": .string("local/own")], model: pane, daemons: daemons)) == ["o1"])
        #expect(try await Self.call(["sessionId": .string("build-host/peer-chat")], model: pane, daemons: daemons) == .null)
        #expect(daemons.reads.map { $0.session } == ["local/peer-chat", "local/own", "local/own"])
    }

    /// A peer may be named `local` (acpmux peer names are any session name), and acpmux keys its
    /// rows `local/<id>`: a read of `local/<id>` that is not the daemon's own chat is forwarded
    /// there. Every forwarded reply names its `peer` (server/peer_forward.rs) and a daemon's own
    /// chat never does, so such a reply answers null and no ask of it reaches the page.
    @Test func aReplyForwardedFromAPeerIsRefused() async throws {
        let daemons = Daemons()
        daemons.pending[Self.mainSocket] = ["own": [["permissionId": "o1"]]]
        daemons.localPeer[Self.mainSocket] = ["peer-chat": [["permissionId": "x1"]]]
        let pane = Self.pane(socket: Self.mainSocket)

        #expect(try await Self.call(["sessionId": .string("peer-chat")], model: pane, daemons: daemons) == .null)
        #expect(Self.permissionIds(try await Self.call(["sessionId": .string("own")], model: pane, daemons: daemons)) == ["o1"])
        #expect(daemons.reads.map { $0.session } == ["local/peer-chat", "local/own"])
    }

    @Test func aChatTheDaemonCannotReadAnswersNull() async throws {
        let daemons = Daemons()
        #expect(try await Self.call(["sessionId": .string("s-gone")], model: Self.pane(socket: Self.mainSocket), daemons: daemons) == .null)
        #expect(daemons.sockets() == [Self.mainSocket])
    }

    /// A pane on another machine's chat (``RemoteAcpmuxWire``, scoped to that one session), a pane
    /// before its handshake and a closed pane have no acpmux socket of their own: they answer null
    /// for every id and read no daemon (PR #22646 review).
    @Test func aPaneWithNoSocketOfItsOwnGetsNullAndReadsNothing() async throws {
        let daemons = Daemons()
        daemons.pending[Self.mainSocket] = ["a-chat-on-this-mac": [["permissionId": "p1"]]]

        let remote = Self.pane(socket: Self.mainSocket)
        remote.remoteChat = true
        #expect(try await Self.call(["sessionId": .string("a-chat-on-this-mac")], model: remote, daemons: daemons) == .null)
        let beforeHandshake = Self.pane(socket: nil)
        #expect(try await Self.call(["sessionId": .string("a-chat-on-this-mac")], model: beforeHandshake, daemons: daemons) == .null)
        // A provider no pane has wired fails closed too.
        let unwired = AgentPageProvider { _ in nil }
        unwired.pendingAsks = daemons.reader
        let reply = try await unwired.call(AgentPageOps.namespace + "chat.asks.pending",
                                           params: .object(["sessionId": .string("a-chat-on-this-mac")]), context: Self.context)
        #expect(reply == .null)
        // A pane that closed (its model is gone) reads nothing either.
        let closed = AgentPageProvider { _ in nil }
        closed.pendingAsks = daemons.reader
        do {
            var gone: AgentPaneModel? = Self.pane(socket: Self.mainSocket)
            closed.pendingAsksSocket = { [weak gone] in gone?.pendingAsksSocket }
            gone = nil
        }
        #expect(try await closed.call(AgentPageOps.namespace + "chat.asks.pending",
                                      params: .object(["sessionId": .string("a-chat-on-this-mac")]), context: Self.context) == .null)
        #expect(daemons.reads.isEmpty)

        // The same read from a pane on this Mac's chat goes through.
        #expect(try await Self.call(["sessionId": .string("a-chat-on-this-mac")], model: Self.pane(socket: Self.mainSocket), daemons: daemons) != .null)
        #expect(daemons.sockets() == [Self.mainSocket])
    }

    @Test func paramsOtherThanOneSessionIdAreRefused() async throws {
        let daemons = Daemons()
        let model = Self.pane(socket: Self.mainSocket)
        await #expect(throws: PageError.self) { _ = try await Self.call([:], model: model, daemons: daemons) }
        await #expect(throws: PageError.self) { _ = try await Self.call(["sessionId": .string("")], model: model, daemons: daemons) }
        await #expect(throws: PageError.self) {
            _ = try await Self.call(["sessionId": .string("s-1"), "method": .string("_acpmux/kill")], model: model, daemons: daemons)
        }
        #expect(daemons.reads.isEmpty)
    }

    @Test func oneReplyCarriesAtMostSixtyFourEntries() async throws {
        let daemons = Daemons()
        daemons.pending[Self.mainSocket] = ["s-1": (0..<100).map { ["permissionId": "p\($0)"] as [String: Any] }]
        let reply = try await Self.call(["sessionId": .string("s-1")], model: Self.pane(socket: Self.mainSocket), daemons: daemons)
        #expect(Self.permissionIds(reply)?.count == 64)
    }
}
