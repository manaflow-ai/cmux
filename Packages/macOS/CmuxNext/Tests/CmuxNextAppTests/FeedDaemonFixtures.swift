import CmuxNextDaemon
import CmuxNextFeedClient
import Foundation

/// Test stand-ins for the daemon's feed client (plans/cmux-next/feed-page.md 2): items and replies
/// written as the wire JSON, and a fake `feed.*` op sender that records each call.
@MainActor
final class FakeFeedDaemon {
    struct Call: Equatable {
        var operation: String
        var params: [String: JSONValue]
    }

    private(set) var calls: [Call] = []
    /// The reply to each op (absent: `{}`).
    var replies: [String: @MainActor ([String: JSONValue]) throws -> JSONValue] = [:]

    var ops: [String] { calls.map(\.operation) }

    lazy var client = FeedDaemonClient { [unowned self] operation, params, _ in
        calls.append(Call(operation: operation, params: params))
        return try replies[operation]?(params) ?? .object([:])
    }

    /// Replies to `operation` with `json`.
    func reply(_ operation: String, _ json: String) {
        let value = Self.json(json)
        replies[operation] = { _ in value }
    }

    nonisolated static func json(_ text: String) -> JSONValue {
        (try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))) ?? .null
    }
}

extension FeedDaemonItem {
    /// An item from its wire JSON (an object literal).
    nonisolated static func wire(_ text: String) throws -> FeedDaemonItem {
        try JSONDecoder().decode(FeedDaemonItem.self, from: Data(text.utf8))
    }
}
