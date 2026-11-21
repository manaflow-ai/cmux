import Foundation

/// Answers the typed requests of a ``DaemonConnection`` that has no daemon transport. A test's model daemon is one:
/// it keeps each request and gives the replies back in the order and at the points that the test picks, so a test
/// of reply order needs no socket, no sleep and no poll. The product sets none.
protocol DaemonRequestAnswering: Sendable {
    /// `request` arrived, on the connection's executor. The answerer resumes `reply` one time: with the JSON of
    /// the reply's `data` object, or with the error that the request throws.
    func receive(_ request: any DaemonRequest, reply: CheckedContinuation<Data, any Error>)
    /// The newest event sequence that the answerer made (``DaemonConnection/eventSequence()``): the write barrier
    /// of a request that it answered.
    var eventSequence: UInt64? { get }
}

/// The answerer of a connection's configuration (``DaemonConnectionConfiguration/answers``), and how a request
/// waits for its reply.
struct DaemonRequestAnswers: Sendable {
    var answerer: (any DaemonRequestAnswering)?

    /// The answerer's reply to `request`. The request waits on `connection`'s own executor, so a reply comes back
    /// with no other hop. With no answerer the request is not connected, as before.
    func answer<R: DaemonRequest>(_ request: R, on connection: isolated DaemonConnection) async throws -> R.Response {
        guard let answerer else { throw DaemonError.notConnected }
        let data: Data = try await withCheckedThrowingContinuation { reply in answerer.receive(request, reply: reply) }
        do {
            return try JSONDecoder().decode(R.Response.self, from: data)
        } catch {
            throw DaemonError.malformedResponse("\(R.self): \(error)")
        }
    }
}
