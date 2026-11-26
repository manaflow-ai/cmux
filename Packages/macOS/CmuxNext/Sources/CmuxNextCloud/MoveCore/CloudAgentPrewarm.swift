public import CmuxNextDaemon
public import Foundation

/// A composer Cloud send's agent, warmed on its machine before the chat's page asks for it (cmux#45953).
///
/// The page starts the chat's agent at its first send (`agent-session-start`), after the copy, the chat's workspace and
/// tab, the folder's trust and the page's own load; the harness's start then ran cold, after all of them (3.4 to 4.3 s
/// on a fresh machine, cmux#45842's measurements), because acpmux never served a pooled agent to a start that carries the
/// owner's model credential. As soon as the tab exists and the copied folder is trusted, the start sends the machine's daemon
/// `agent-session-prewarm` with the start's own values (folder, agent, model, mode, permission mode and the chat's launch
/// credential, read as the start reads them); acpmux warms that agent beside the page's load, and the start that
/// follows takes it. A machine whose daemon does not serve it, a prewarm that fails, or a start that ends up different
/// (another agent or model picked) starts cold, as before: the prewarm decides nothing and nothing waits for it.
public struct CloudAgentPrewarm: Sendable, Equatable {
    public let cwd: String
    public let harness: String?
    public let model: String?
    public let mode: String?

    /// What the chat's page's first send will start: the seed's agent, model and mode in the copied folder `cwd`. Nil when
    /// there is nothing to warm: no absolute folder there (the start makes its own `~/chats/<id>`), or a daemon that does
    /// not serve the verb (`served`, ``AgentSessionAttachClient/prewarmCapability``).
    public init?(cwd: String?, harness: String?, model: String?, mode: String?, served: Bool) {
        guard served, let cwd, cwd.hasPrefix("/") else { return nil }
        (self.cwd, self.harness, self.model, self.mode) = (cwd, harness, model, mode)
    }

    /// ``send(surface:endpoint:ownerLink:permissionMode:credentials:)`` with nothing waiting for it: `credentials` reads the chat's
    /// launch credential as the start reads it (never spending it), and `done` gets the outcome for the log.
    public func begin(surface: UInt64, endpoint: @escaping AgentSessionAttachClient.EndpointProvider, ownerLink: @escaping AgentSessionAttachClient.OwnerLink,
                      permissionMode: String?, credentials: @escaping @MainActor @Sendable () async -> [String: String]?,
                      done: @escaping @Sendable (String) -> Void) {
        // task-owner: one hint, never awaited by the start; it ends with its answer
        Task { done(await send(surface: surface, endpoint: endpoint, ownerLink: ownerLink, permissionMode: permissionMode, credentials: await credentials())) }
    }

    /// Sends the prewarm for the chat tab `surface` over the owner answer of its link (`ownerLink`), with the start's
    /// `permissionMode` and the chat's launch `credentials`; answers what happened, for the log (never a value sent).
    public func send(surface: UInt64, endpoint: @escaping AgentSessionAttachClient.EndpointProvider, ownerLink: @escaping AgentSessionAttachClient.OwnerLink,
                     permissionMode: String?, credentials: [String: String]?) async -> String {
        let client = AgentSessionAttachClient(surface: surface, endpoint: endpoint), outcome: String
        do {
            let accepted = try await client.prewarm(cwd: cwd, harness: harness, ownerLink: ownerLink, model: model,
                                                    permissionMode: permissionMode, startMode: mode, credentials: credentials)
            outcome = accepted ? "accepted" : "not accepted"
        } catch {
            outcome = "not sent (\(String(describing: error)))"
        }
        await client.close() // its one connection
        return outcome
    }
}

/// The copy's preflight of a send's folder (`start-chat-preflight`, a read: no machine, nothing sent), begun as the start
/// begins so it runs beside Cloud first use's read rather than after it (cmux#45953). The start takes its answer only for
/// the folder it then checks (``root``); anything else runs its own.
public struct CloudStartPreflight: Sendable {
    public let root: String
    private let answer: Task<CloudMoveCLI.StartChatPreflight, Never>

    public init(root: String, cli: CloudMoveCLI) {
        self.root = root
        // task-owner: the start that made it awaits it (``answer(_:root:cli:)``) or cancels it (``cancel()``)
        answer = Task { await cli.startChatPreflightAnswer(local: root) }
    }

    public func cancel() { answer.cancel() }

    /// The preflight's answer for `root`: `early`'s when it is for that folder, else a run of its own.
    public static func answer(_ early: CloudStartPreflight?, root: String, cli: CloudMoveCLI) async -> CloudMoveCLI.StartChatPreflight {
        if let early, early.root == root {
            // Cancelling the send ends the early read too, never waits it out.
            return await withTaskCancellationHandler { await early.answer.value } onCancel: { early.cancel() }
        }
        return await cli.startChatPreflightAnswer(local: root)
    }
}
