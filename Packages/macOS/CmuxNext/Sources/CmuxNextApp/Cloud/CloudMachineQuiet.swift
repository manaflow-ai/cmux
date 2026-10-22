import AppKit
import CmuxNextDaemon
import Foundation

/// What the app can see of the work on a Cloud machine, for its automatic update
/// (``CloudMachineUpdateTarget``). The update ends only the machine's cmux-tui daemon: every
/// terminal host and chat keeps running and the next daemon adopts them (cmux-tui
/// `link/machine_update/apply.rs`). Still, a turn's stream, a CLI call in flight and a person typing
/// there feel the restart. The shared policy updates at once and skips this read (its
/// `updateBusyAfter` is zero); a policy with a non-zero `updateBusyAfter` waits until every signal
/// is idle, up to that cap, then runs anyway and skips this read.
/// A pure value: ``isQuiet`` is the whole decision, ``read(_:personIdle:)`` the live reads.
nonisolated struct CloudMachineQuiet: Sendable, Equatable {
    /// The machine's acpmux chats in a turn or waiting on a permission, sub-sessions included
    /// (`agent-update-plan`'s `running_threads`; none mirrored from a peer).
    enum Chats: Sendable, Equatable {
        case inTurn(Int)
        /// The daemon predates `agent-update-v1` and cannot say.
        case unreported
        /// The read failed.
        case unreadable
    }

    /// The person gave no input for a minute, or the app is in the background.
    var personIdle: Bool
    /// Clients of the machine's daemon that do not come back after a restart: a `cmux chief`
    /// chat, a terminal UI, a `cmux` call in flight (nil: not read, or unreadable).
    var stayingClients: Int?
    /// Conversations someone types in: a Chief's turn (nil: not read, or unreadable).
    var typingConversations: Int?
    /// Terminal agents working or waiting on a permission (`list-agents`; nil: not read, or unreadable).
    var busyTerminalAgents: Int?
    var chats: Chats = .unreadable

    var isQuiet: Bool {
        guard personIdle, stayingClients == 0, typingConversations == 0, busyTerminalAgents == 0 else { return false }
        switch chats {
        case .inTurn(let count): return count == 0
        // A daemon from before `agent-update-v1` cannot name its chats' turns. Its update still
        // keeps every chat process running (only the daemon ends), so the other signals decide;
        // else a machine on such a build could never update by itself.
        case .unreported: return true
        case .unreadable: return false
        }
    }

    /// The daemon capability of `agent-update-plan`.
    static let chatTurnsCapability = "agent-update-v1"

    /// Reads the machine through its daemon `connection`, cheapest first; it stops at the first
    /// busy signal (the rest stay nil).
    static func read(_ connection: DaemonConnection, personIdle: Bool) async -> CloudMachineQuiet {
        var quiet = CloudMachineQuiet(personIdle: personIdle)
        guard personIdle else { return quiet }
        let relay = ResourceRelayClient(connection: connection)
        quiet.stayingClients = await stayingClients(relay)
        guard quiet.stayingClients == 0 else { return quiet }
        quiet.typingConversations = await typingConversations(relay)
        guard quiet.typingConversations == 0 else { return quiet }
        quiet.busyTerminalAgents = try? await connection.request(ListAgentsRequest()).agents.count { $0.state == .working || $0.state == .blocked }
        guard quiet.busyTerminalAgents == 0 else { return quiet }
        quiet.chats = await chats(connection)
        return quiet
    }

    /// `client.list`, other than this connection, by the rule of the local quiet restart
    /// (`OwnerIdleProbe.Clients.reconnecting`): this app's and other apps' connections and pages
    /// reconnect by themselves; a chat or terminal UI, and a local client without a kind (a `cmux`
    /// call in flight), do not.
    private static func stayingClients(_ relay: ResourceRelayClient) async -> Int? {
        guard let list = try? await relay.send(operation: "client.list", params: [:], idempotencyKey: nil) else { return nil }
        return (list.arrayValue ?? []).count { client in
            guard client["self"]?.boolValue != true else { return false }
            guard let kind = client["client_kind"]?.stringValue else { return client["transport"]?.stringValue == "unix" }
            return OwnerIdleProbe.interactiveClientKinds.contains(kind)
        }
    }

    /// Conversations whose `typing` set is not empty. A daemon that does not list conversations
    /// (an older build) has none; a conversation that cannot be read counts as typing.
    private static func typingConversations(_ relay: ResourceRelayClient) async -> Int? {
        guard let list = try? await relay.send(operation: "conversation.list", params: [:], idempotencyKey: nil) else { return 0 }
        var typing = 0
        for summary in list.arrayValue ?? [] {
            guard let id = summary["id"]?.stringValue,
                  let snapshot = try? await relay.send(operation: "conversation.get", params: ["conversation": .string(id), "tail": .number(1)],
                                                       idempotencyKey: nil) else { return nil }
            if snapshot["typing"]?.arrayValue?.isEmpty != true { typing += 1 }
        }
        return typing
    }

    private static func chats(_ connection: DaemonConnection) async -> Chats {
        guard await connection.identity?.supports(chatTurnsCapability) == true else { return .unreported }
        do {
            return .inTurn(try await connection.request(AgentUpdatePlanRequest(), timeout: AgentUpdatePlanRequest.timeout).runningThreads)
        } catch let DaemonError.command(_, _, code, _, _) where code == "agent_update.unavailable" {
            // The daemon has no acpmux: no chat runs there.
            return .inTurn(0)
        } catch {
            return .unreadable
        }
    }

    /// The person gives no input now: the app is in the background, or no input came for
    /// `seconds`; never inside a menu, drag or resize tracking loop (the local quiet restart's
    /// rule, `QuietDaemonUpdate`).
    @MainActor
    static func personIsIdle(after seconds: TimeInterval = 60) -> Bool {
        guard RunLoop.main.currentMode == .default || RunLoop.main.currentMode == nil else { return false }
        guard NSApp?.isActive == true else { return true }
        let anyInput = CGEventType(rawValue: ~0) ?? .null
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput) >= seconds
    }
}

/// `agent-update-plan {}` (`agent-update-v1`, cmux-tui `server/agent_transfer/agent_update.rs`): a
/// read that starts nothing. Only `running_threads` is used: the machine's acpmux chats in a turn
/// (`running`) or waiting on a permission (`waiting`), sub-sessions included.
nonisolated struct AgentUpdatePlanRequest: DaemonRequest {
    struct Response: Decodable, Sendable {
        var runningThreads: Int

        enum CodingKeys: String, CodingKey {
            case runningThreads = "running_threads"
        }
    }

    static let command = "agent-update-plan"
    static let requiredCapability: String? = CloudMachineQuiet.chatTurnsCapability
    /// The plan reads acpmux's harness health first, which may take up to 60 s on a cold acpmux.
    static let timeout: Duration = .seconds(75)
}
