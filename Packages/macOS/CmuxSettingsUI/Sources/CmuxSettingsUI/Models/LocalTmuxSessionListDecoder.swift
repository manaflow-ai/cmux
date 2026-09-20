import Foundation

/// Decodes the bounded JSON emitted by cmux local-tmux list --json.
///
/// The decoder rejects malformed lifecycle state instead of projecting a
/// partially valid row into Settings. It performs no I/O and can be exercised
/// without launching the cmux app.
nonisolated public struct LocalTmuxSessionListDecoder: Sendable {
    /// A malformed or internally inconsistent session-list payload.
    public enum Failure: Error, Sendable, Equatable {
        /// The response or one of its session rows violates the CLI contract.
        case invalidResponse
    }

    private struct Response: Decodable {
        let sessions: [Session]

        struct Session: Decodable {
            let id: String?
            let sessionName: String
            let cwd: String?
            let clients: Int?
            let managed: Bool
            let live: Bool

            enum CodingKeys: String, CodingKey {
                case id
                case sessionName = "session_name"
                case cwd
                case clients
                case managed
                case live
            }
        }
    }

    /// Creates a stateless session-list decoder.
    public init() {}

    /// Decodes and validates one CLI response.
    ///
    /// Live sessions sort before stale sessions, then by localized
    /// case-insensitive name. Managed rows require a logical UUID; unmanaged
    /// rows intentionally keep a nil logical id and a tmux:<name> identity.
    ///
    /// - Parameter data: UTF-8 JSON bytes from cmux local-tmux list --json.
    /// - Returns: Validated session summaries in Settings display order.
    /// - Throws: Failure.invalidResponse for malformed JSON or rows that
    ///   violate the lifecycle contract.
    public func decode(_ data: Data) throws -> [LocalTmuxSessionSummary] {
        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw Failure.invalidResponse
        }

        return try response.sessions.map { row in
            guard !row.sessionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw Failure.invalidResponse
            }

            let logicalID: UUID?
            if row.managed {
                guard let rawID = row.id,
                      let parsedID = UUID(uuidString: rawID) else {
                    throw Failure.invalidResponse
                }
                logicalID = parsedID
            } else {
                guard row.id == nil else {
                    throw Failure.invalidResponse
                }
                logicalID = nil
            }

            return LocalTmuxSessionSummary(
                selector: logicalID.map { .managed(id: $0, name: row.sessionName) }
                    ?? .unmanaged(name: row.sessionName),
                cwd: row.cwd,
                clientCount: row.clients ?? 0,
                isLive: row.live
            )
        }
        .sorted {
            if $0.isLive != $1.isLive {
                return $0.isLive && !$1.isLive
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}
