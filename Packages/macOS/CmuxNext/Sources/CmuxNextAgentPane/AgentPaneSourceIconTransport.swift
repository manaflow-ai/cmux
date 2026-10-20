import CmuxNextPages
import Foundation

/// One chain's HTTP answers, including redirect hops; failed connections may try another checked address.
actor AgentPaneSourceIconTransport: RemoteFetchTransport {
    private struct Target: Hashable {
        let host: String
        let port: Int
        let path: String
    }
    private let base: any RemoteFetchTransport
    private var responses: [Target: Int] = [:]
    private var statuses: [Int?] = []

    init(_ base: any RemoteFetchTransport) { self.base = base }

    func send(_ request: RemoteFetchRequest, maximumBytes: Int) async throws -> RemoteFetchResponse {
        let target = Target(host: request.host, port: request.port, path: request.target)
        guard responses[target] == nil else { throw CancellationError() }
        let index = statuses.count
        statuses.append(nil)
        let response = try await base.send(request, maximumBytes: maximumBytes)
        responses[target] = response.status
        statuses[index] = response.status
        return response
    }

    /// A checkpoint separates each guarded fetch's hops from earlier steps in this chain.
    func checkpoint() -> Int { statuses.count }

    /// A successful address fallback supersedes connection failures for the same hop.
    /// A missing final answer or any transient HTTP status prevents negative caching.
    func needsRetry(since checkpoint: Int) -> Bool {
        let replies = statuses.dropFirst(checkpoint)
        guard let last = replies.last, last != nil else { return true }
        return replies.contains { status in
            guard let status else { return false }
            return status == 429 || (500..<600).contains(status)
        }
    }
}
