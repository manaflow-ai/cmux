#if os(iOS)
import CmuxMobileAgentChat
import Foundation
import Observation

/// A Cloud machine screen's chat channel, opened once per attempt and owned by the screen's state,
/// not by a view's `.task`. A kept chat tapped while the channel opens pushes a screen over the
/// list; SwiftUI then cancels the list's `.task`, and a connect run there never assigned its relay
/// (the screen stayed a spinner after the Mac answered). The connect here runs in its own task,
/// so it finishes whatever is pushed over the list, and the pushed chat opens once it is ready.
@MainActor @Observable
public final class CloudMachineConnection {
    /// What a chat tapped on the machine's screen shows now.
    public enum Destination {
        /// The machine's channel is ready and lists the chat.
        case chat(AgentChatStore)
        /// A kept chat tapped before the channel is ready: it opens in place once it is.
        case waiting
        case unavailable
    }

    public private(set) var relay: CloudChatRelay?
    /// The connect failed (nil while it may still finish).
    public private(set) var error: String?
    /// ``CloudChatsMemory/generation`` when `relay`'s connect began: its lists are kept only while
    /// no sign-out has come since.
    public private(set) var relayGeneration: Int?
    @ObservationIgnored private var attempt: Int?
    /// The attempt's connect. It holds the connection weakly: a screen gone for good drops the
    /// answer (the coordinator bounds the connect itself).
    @ObservationIgnored private var task: Task<Void, Never>?

    public init() {}

    /// Opens the channel for `attempt` (the screen's Reconnect count). The same attempt again (the
    /// list shown again after a pushed chat is popped) is a no-op: one connect per attempt.
    public func open(attempt: Int, connect: (@MainActor () async throws -> CloudChatRelay)?) {
        guard attempt != self.attempt else { return }
        self.attempt = attempt
        task?.cancel()
        error = nil
        guard let connect else {
            error = "Connect your Mac."
            return
        }
        let generation = CloudChatsMemory.shared.generation
        task = Task { [weak self] in
            do {
                let opened = try await connect()
                guard let self, !Task.isCancelled, self.attempt == attempt else { return }
                relayGeneration = generation
                relay = opened
            } catch {
                guard let self, !Task.isCancelled, self.attempt == attempt else { return }
                self.error = "Couldn't connect. Try again."
            }
        }
    }

    /// What `sessionID`, tapped on the screen, shows now; `kept` is the screen's kept chats.
    public func destination(for sessionID: String, kept: [AcpmuxSession]?) -> Destination {
        if let store = relay?.store(sessionID: sessionID) { return .chat(store) }
        let failed = error != nil || relay?.error != nil || relay?.hub.lastError != nil
        if relay?.hub.isReady != true, !failed, kept?.contains(where: { $0.id == sessionID }) == true { return .waiting }
        return .unavailable
    }
}
#endif
