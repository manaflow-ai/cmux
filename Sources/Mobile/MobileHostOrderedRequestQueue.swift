import Foundation

struct MobileHostOrderedRequest: Sendable {
    let frameByteCount: Int
    let decodedRequest: Result<MobileHostRPCRequest, MobileHostRPCError>
}

struct MobileHostOrderedRequestQueue {
    private var requests: [MobileHostOrderedRequest] = []

    var isEmpty: Bool { requests.isEmpty }
    var frameByteCounts: [Int] { requests.map(\.frameByteCount) }

    mutating func enqueue(_ request: MobileHostOrderedRequest) {
        requests.append(request)
    }

    mutating func dequeue() -> MobileHostOrderedRequest? {
        guard !requests.isEmpty else { return nil }
        return requests.removeFirst()
    }

    mutating func removeAll() {
        requests.removeAll()
    }
}

extension MobileHostRPCRequest {
    /// Whether this request can write terminal input and must therefore be
    /// handled in arrival order rather than on a concurrent response task.
    /// paste_image belongs here because its handler writes the materialized
    /// image path into the PTY; scroll and mouse belong here because their
    /// handlers emit mouse-report bytes when the terminal has mouse reporting
    /// active, and either could otherwise overtake earlier queued keystrokes.
    var isOrderedTerminalInput: Bool {
        switch method {
        case "mobile.terminal.input", "terminal.input",
             "mobile.terminal.paste", "terminal.paste",
             "mobile.terminal.paste_image", "terminal.paste_image",
             "mobile.terminal.scroll", "terminal.scroll",
             "mobile.terminal.mouse", "terminal.mouse":
            true
        default:
            false
        }
    }

    /// The fallback ordering domain for an ordered terminal request.
    /// Production admission resolves aliases and focused targets against the
    /// live main-actor topology before choosing the final FIFO key.
    var orderedInputSurfaceKey: String {
        for key in ["surface_id", "terminal_id", "tab_id"] {
            let raw = (params[key] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !raw.isEmpty else { continue }
            // UUID spelling is not identity. Normalize it before the fallback
            // admission queue so upper/lower-case wire variants cannot race
            // one another when the live topology resolver is unavailable.
            return UUID(uuidString: raw)?.uuidString.lowercased() ?? raw
        }
        // Requests without a direct alias share one conservative bucket. The
        // production resolver replaces this with the focused/handle target.
        return ""
    }
}

/// A connection-scoped identity for terminal input that is shared by the
/// control RPC and Iroh input lanes. The token is deliberately opaque: a
/// reconnect receives a new value and all work admitted by the old value is
/// rejected before it can touch the PTY.
struct MobileTerminalInputOrderingToken: Hashable, Sendable {
    fileprivate let rawValue: UUID

    fileprivate init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

/// A reservation in the canonical per-surface input order. Callers wait for
/// `turn` before applying the mutation and always call `finish` afterwards,
/// including when the token has become stale.
struct MobileTerminalInputOrderingTicket: Sendable {
    fileprivate let id: UUID
    fileprivate let surfaceID: UUID
    fileprivate let token: MobileTerminalInputOrderingToken
    fileprivate let turn: Task<Void, Never>

    func waitForTurn() async {
        await turn.value
    }
}

/// Main-actor owner for every PTY-writing mobile input path.
///
/// RPC control frames and Iroh input lanes arrive through independent actor
/// trees. Keeping their reservation and execution fence here gives both paths
/// one canonical UUID queue, one reconnect epoch, and one input-sequence
/// watermark. The existing connection-local RPC queue remains useful for
/// response admission and quota accounting; this owner is the PTY ordering
/// authority.
@MainActor
final class MobileTerminalInputOrdering {
    enum Rejection: Error, Equatable, Sendable {
        case inactiveConnection
        case staleSequence
    }

    private struct SurfaceSequenceKey: Hashable {
        let surfaceID: UUID
        let token: MobileTerminalInputOrderingToken
    }

    private var activeTokens: Set<MobileTerminalInputOrderingToken> = []
    private var tokenByIdentity: [String: MobileTerminalInputOrderingToken] = [:]
    private var identityByToken: [MobileTerminalInputOrderingToken: String] = [:]
    private var lastSequenceBySurfaceAndToken: [SurfaceSequenceKey: UInt64] = [:]
    private var tailsBySurfaceID: [UUID: (ticketID: UUID, task: Task<Void, Never>)] = [:]
    private var finishSignalsByTicketID: [UUID: AsyncStream<Void>.Continuation] = [:]

    func beginConnection(identity: String? = nil) -> MobileTerminalInputOrderingToken {
        let token = MobileTerminalInputOrderingToken()
        activeTokens.insert(token)
        if let identity = normalizedIdentity(identity) {
            if let previous = tokenByIdentity[identity], previous != token {
                invalidate(previous)
            }
            tokenByIdentity[identity] = token
            identityByToken[token] = identity
        }
        return token
    }

    func rebind(
        _ token: MobileTerminalInputOrderingToken,
        identity: String
    ) {
        guard activeTokens.contains(token),
              let identity = normalizedIdentity(identity) else {
            return
        }
        if let previous = tokenByIdentity[identity], previous != token {
            invalidate(previous)
        }
        // Keep the original transport identity mapped as well. Iroh binds a
        // token to its peer and an authorized RPC may later add the phone's
        // client id; a reconnect can arrive with either identity first.
        tokenByIdentity[identity] = token
        identityByToken[token] = identity
    }

    func invalidate(_ token: MobileTerminalInputOrderingToken) {
        guard activeTokens.remove(token) != nil else { return }
        lastSequenceBySurfaceAndToken = lastSequenceBySurfaceAndToken.filter {
            $0.key.token != token
        }
        identityByToken.removeValue(forKey: token)
        tokenByIdentity = tokenByIdentity.filter { $0.value != token }
    }

    func reserve(
        surfaceID: UUID,
        token: MobileTerminalInputOrderingToken,
        inputSequence: UInt64?
    ) -> Result<MobileTerminalInputOrderingTicket, Rejection> {
        guard activeTokens.contains(token) else {
            return .failure(.inactiveConnection)
        }
        if let inputSequence {
            let key = SurfaceSequenceKey(surfaceID: surfaceID, token: token)
            if let previous = lastSequenceBySurfaceAndToken[key], inputSequence <= previous {
                return .failure(.staleSequence)
            }
            // Advance at reservation time, not after execution. A later lane
            // frame must not be admitted behind a queued older frame and then
            // make the older frame look fresh when it finally runs.
            lastSequenceBySurfaceAndToken[key] = inputSequence
        }

        let ticketID = UUID()
        let predecessor = tailsBySurfaceID[surfaceID]?.task
        let turn = Task {
            if let predecessor {
                await predecessor.value
            }
        }
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let tail = Task {
            await turn.value
            for await _ in stream { break }
        }
        tailsBySurfaceID[surfaceID] = (ticketID: ticketID, task: tail)
        finishSignalsByTicketID[ticketID] = continuation
        return .success(MobileTerminalInputOrderingTicket(
            id: ticketID,
            surfaceID: surfaceID,
            token: token,
            turn: turn
        ))
    }

    func isCurrent(_ ticket: MobileTerminalInputOrderingTicket) -> Bool {
        activeTokens.contains(ticket.token)
    }

    func finish(_ ticket: MobileTerminalInputOrderingTicket) {
        guard let continuation = finishSignalsByTicketID.removeValue(forKey: ticket.id) else {
            return
        }
        continuation.yield(())
        continuation.finish()
        if tailsBySurfaceID[ticket.surfaceID]?.ticketID == ticket.id {
            tailsBySurfaceID[ticket.surfaceID] = nil
        }
    }

    private func normalizedIdentity(_ identity: String?) -> String? {
        guard let identity else { return nil }
        let value = identity.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
