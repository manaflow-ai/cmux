@testable import CmuxNextAgentPane
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// The agent page's `chat.rows.*` route (``AgentPaneChatRows``): its checks before any socket work.
/// The host behind it is tested in CmuxNextDaemonTests (AcpmuxChatRows*Tests).
@MainActor
@Suite struct AgentPaneChatRowsTests {
    private let context = PageCallContext(page: PageDescriptor.agent.id)

    private func code(_ body: () async throws -> JSONValue) async -> String? {
        do {
            _ = try await body()
            return nil
        } catch let error as PageError {
            return error.code
        } catch {
            return "other"
        }
    }

    @Test func theFiveOpsAreAgentPageOps() {
        for name in ["open", "close", "page", "blob", "taken"] {
            #expect(AgentPageOps.method(for: AgentPaneChatRows.prefix + name) == "chat.rows.\(name)")
        }
        #expect(AgentPaneChatRows.prefix.hasPrefix(AgentPageOps.namespace))
    }

    @Test func openForAChatThatIsNotThePanesIsRefusedAndSendsNoSub() async {
        let rows = AgentPaneChatRows(model: nil)
        rows.socket = { "/tmp/no-such-acpmux.sock" }
        rows.holdsSession = { $0 == "mine" }
        var made = 0
        let original = rows.makeHost
        rows.makeHost = { path, deliver in
            made += 1
            return original(path, deliver)
        }
        let open = JSONValue.object(["sid": .string("abc.1"), "chat": .string("not-mine"), "anchor": .string("end")])
        #expect(await code { try await rows.call(AgentPaneChatRows.prefix + "open", params: open, context: context) }
            == AgentPaneTransportError.sessionNotInPane.rawValue)
        #expect(made == 0 && rows.host == nil, "no handle, so no sub")
    }

    @Test func noSocketIsOff() async {
        let rows = AgentPaneChatRows(model: nil)
        rows.socket = { nil }
        rows.holdsSession = { _ in true }
        let open = JSONValue.object(["sid": .string("abc.1"), "chat": .string("mine")])
        #expect(await code { try await rows.call(AgentPaneChatRows.prefix + "open", params: open, context: context) } == "chat.rows.off")
        // With no host, a close, a page or a blob names nothing this page opened; taken is a no-op.
        let close = JSONValue.object(["sid": .string("abc.1")])
        #expect(await code { try await rows.call(AgentPaneChatRows.prefix + "close", params: close, context: context) } == "chat.rows.name")
        #expect(await code { try await rows.call(AgentPaneChatRows.prefix + "taken", params: .object(["batch": .number(1)]), context: context) } == nil)
    }

    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// A local pane before its handshake has no socket yet: that chat alone is refused, with a code
    /// that is none of the four `chat.rows.*` ones, so the page does not run v1 for the document.
    /// A chat on another machine still answers `chat.rows.off`.
    @Test func noSocketYetRefusesThatChatAloneAndAnotherMachineIsOff() async {
        let model = AgentPaneModel(host: NoHost())
        model.transport.sessions.add("mine")
        let rows = AgentPaneChatRows(model: model)
        let open = JSONValue.object(["sid": .string("abc.1"), "chat": .string("mine")])
        let notYet = await code { try await rows.call(AgentPaneChatRows.prefix + "open", params: open, context: context) }
        #expect(notYet == AgentPaneTransportError.noConnection.rawValue)
        #expect(rows.host == nil, "no handle before the pane's socket is known")
        model.remoteChat = true
        #expect(await code { try await rows.call(AgentPaneChatRows.prefix + "open", params: open, context: context) } == "chat.rows.off")
    }

    @Test func malformedParamsAreRefused() async {
        let rows = AgentPaneChatRows(model: nil)
        #expect(await code { try await rows.call(AgentPaneChatRows.prefix + "open", params: .object([:]), context: context) } == "cmux.protocol.invalid_params")
        #expect(await code { try await rows.call(AgentPaneChatRows.prefix + "taken", params: .object([:]), context: context) } == "cmux.protocol.invalid_params")
        #expect(await code { try await rows.call(AgentPaneChatRows.prefix + "other", params: .object(["sid": .string("a.1")]), context: context) } != nil)
    }
}
