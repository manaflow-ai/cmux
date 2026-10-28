import CmuxNextChiefMemory
import CmuxNextDaemon
import Foundation

/// The Memory Inspector's ``ChiefMemorySource`` in the app: each call is one
/// `chief-inspect` request over the daemon in front of the Chief's brain
/// (this Mac's Chief owner daemon, or a paired server's), which forwards it
/// to the brain's tools socket. No localhost server, port or token.
nonisolated struct DaemonChiefMemorySource: ChiefMemorySource {
    /// A Chief that is not the default (the reserved `chief` query key); nil: the default.
    let chief: String?
    let connection: @MainActor @Sendable () -> DaemonConnection?

    init(chief: String?, connection: @escaping @MainActor @Sendable () -> DaemonConnection?) {
        self.chief = chief
        self.connection = connection
    }

    func call(_ path: String, query: [String: String]) async throws(ChiefMemoryError) -> Data {
        guard let connection = await connection() else { throw .unreachable }
        var query = query
        if let chief { query["chief"] = chief }
        let answer: ChiefInspectResult
        do {
            answer = try await connection.request(ChiefInspectRequest(path: path, query: query))
        } catch {
            throw .unreachable
        }
        guard answer.status == 200, let body = answer.body else {
            throw .refused(status: Int(answer.status), message: answer.error ?? "HTTP \(answer.status)")
        }
        do {
            return try JSONEncoder().encode(body)
        } catch {
            throw .malformed
        }
    }
}
