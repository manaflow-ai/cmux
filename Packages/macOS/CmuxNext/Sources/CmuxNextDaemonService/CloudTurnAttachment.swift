import CmuxNextAgentPane
import CmuxNextCompat
import CmuxNextDaemon
import Foundation

/// A turn capability belongs to the owner connection that opened this attachment. An old
/// attachment must never borrow a replacement link's owner proof after a rewind.
nonisolated struct CloudTurnAttachment: Sendable {
    let endpoint: AgentSessionAttachClient.EndpointProvider
    let turn: RemoteAcpmuxWire.CloudTurn?

    init(endpoint: @escaping AgentSessionAttachClient.EndpointProvider,
         ownerLink: AgentSessionAttachClient.OwnerLink?, turn: RemoteAcpmuxWire.CloudTurn?) {
        guard let turn else { self.endpoint = endpoint; self.turn = nil; return }
        let ticket = Mutex<Int?>(nil)
        let refused: @Sendable () -> AgentSessionRemoteError = { AgentSessionRemoteError(code: "cloud.turn.connection", message: "Reconnect this Cloud chat before sending another turn.") }
        let verify: @Sendable () async throws -> Void = {
            guard let expected = ticket.withLock({ $0 }), let ownerLink, await ownerLink() == expected else { throw refused() }
        }
        self.endpoint = {
            guard let ownerLink, let current = await ownerLink() else { throw refused() }
            let value = try await endpoint()
            guard await ownerLink() == current else { throw refused() }
            let accepted = ticket.withLock { ticket in
                if let ticket { return ticket == current }
                ticket = current
                return true
            }
            guard accepted else { throw refused() }
            return value
        }
        self.turn = .init(state: { session, prompt in
            try await verify()
            let value = try await turn.state(session, prompt)
            try await verify()
            return value
        }, capture: { session, prompt, prepared, state in
            try await verify()
            // The capture CAS checks the verified generation and then holds the external fence.
            // It must not be discarded after mint: the guest needs it to finish that reservation.
            return try await turn.capture(session, prompt, prepared, state)
        })
    }
}
