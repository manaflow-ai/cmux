import Foundation
import Synchronization

/// The replies the relay filters (``AcpmuxPaneMethods/replyShapes``): the transport registers a
/// request's id before it sends the request, and the socket cuts the reply off the main thread,
/// before the page can see it.
public nonisolated final class AcpmuxReplyFilter: Sendable {
    private let waiting = Mutex([String: String]())

    public init() {}

    /// The pane is about to send `method` with raw id `id`.
    func expect(method: String, id: String?) {
        guard let id, AcpmuxPaneMethods.replyShapes[method] != nil else { return }
        waiting.withLock { $0[id] = method }
    }

    func clear() { waiting.withLock { $0.removeAll() } }

    /// A daemon frame, filtered when it answers a registered request.
    func filter(_ text: String) -> String {
        guard waiting.withLock({ !$0.isEmpty }),
              let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              object["method"] == nil, let id = object["id"].flatMap(AcpmuxPaneMethods.rawID),
              let method = waiting.withLock({ $0.removeValue(forKey: id) }),
              let shape = AcpmuxPaneMethods.replyShapes[method] else { return text }
        return AcpmuxPaneMethods.filteredReply(text, shape: shape)
    }
}
