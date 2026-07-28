import Foundation

/// Converts URLSession delegate callbacks into a thread-safe async signal.
///
/// The object is used concurrently only by URLSession. Its state is immutable,
/// and `AsyncStream.Continuation` is safe to yield from concurrent callbacks.
final class ShareSocketOpenDelegate:
    NSObject,
    URLSessionWebSocketDelegate,
    @unchecked Sendable
{
    enum Event: Sendable {
        case opened
        case closed(code: Int, reason: String?)
        case failed
    }

    let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation

    override init() {
        let pair = AsyncStream.makeStream(
            of: Event.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        events = pair.stream
        continuation = pair.continuation
        super.init()
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        continuation.yield(.opened)
        continuation.finish()
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        continuation.yield(.closed(
            code: Int(closeCode.rawValue),
            reason: Self.boundedCloseReason(reason)
        ))
        continuation.finish()
    }

    static func boundedCloseReason(_ data: Data?) -> String? {
        guard let data,
              data.count <= 123,
              let reason = String(data: data, encoding: .utf8) else {
            return nil
        }
        return reason
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        guard error != nil else { return }
        continuation.yield(.failed)
        continuation.finish()
    }

    deinit {
        continuation.finish()
    }
}
