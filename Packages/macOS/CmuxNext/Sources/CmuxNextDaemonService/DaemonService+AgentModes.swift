import CmuxNextCompat
import CmuxNextDaemon
import os

/// The bypass warning for chats of another machine that this app does not show (cx-k21v): at each
/// connect, the mode of every agent tab of this machine's store that is bound to a chat of its own
/// (`registry:` host) is read once (`agent-session-mode`), and so is each tab bound later (one an
/// agent adopted there). A shown chat's attachment keeps its mode current after that
/// (`AgentSessionAttachClient`). Nothing is read on a timer.
extension DaemonService {
    /// Ends this connection's reads (a reconnect or the shutdown).
    func endAgentModeReads() {
        agentModeReads?.cancel()
        agentModeReads = nil
    }

    /// Starts the reads of this connection, ending the previous connection's.
    func readAgentModes() {
        endAgentModeReads()
        guard let endpoint = remoteEndpoint else { return }
        let store = store
        // task-owner: one watch per connection, cancelled by the next connect; it ends with the stream
        agentModeReads = Task { @MainActor [logger] in
            var read: Set<BoundChat> = []
            for await bound in ObservationStream({ Self.boundChats(in: store) }) {
                for chat in bound.subtracting(read) {
                    read.insert(chat)
                    do {
                        let answer = try await AgentSessionAttachClient.readMode(surface: chat.surface, endpoint: endpoint)
                        // A read of an earlier connection (cancelled by the next connect or the
                        // shutdown) never overwrites what the current one says.
                        if Task.isCancelled { return }
                        if let answer { AgentBypassSessions.note(.answer, of: answer) }
                    } catch {
                        logger.info("agent mode read of surface \(chat.surface, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                    }
                    if Task.isCancelled { return }
                }
            }
        }
    }

    struct BoundChat: Hashable, Sendable {
        let surface: UInt64
        let session: String
    }

    /// The tabs of `store` bound to a chat of that machine.
    static func boundChats(in store: DaemonStore) -> Set<BoundChat> {
        var chats: Set<BoundChat> = []
        for workspace in store.workspaces {
            for screen in workspace.screens {
                for pane in screen.panes {
                    for tab in pane.tabs {
                        guard let ref = tab.agentSession, ref.host.hasPrefix("registry:"), let session = ref.session else { continue }
                        chats.insert(BoundChat(surface: tab.surface.rawValue, session: session))
                    }
                }
            }
        }
        return chats
    }
}
