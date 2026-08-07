public import Foundation

public enum CmuxTUIClientError: Error, LocalizedError, Sendable {
    case libraryUnavailable(searchedPaths: [String])
    case message(String)
    case invalidRenderEvent(String)

    public var errorDescription: String? {
        switch self {
        case .libraryUnavailable(let searchedPaths):
            return "cmux-tui client library unavailable; searched: \(searchedPaths.joined(separator: ", "))"
        case .message(let message), .invalidRenderEvent(let message):
            return Self.readableMessage(message)
        }
    }

    private static func readableMessage(_ message: String) -> String {
        guard let data = message.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let readable = object["message"] as? String else {
            return message
        }
        return readable
    }
}

public struct CmuxTUIUpdateSubscription: Sendable {
    public let generation: UInt64
    public let stream: AsyncStream<Void>
}

public struct CmuxTUITerminalGeometry: Equatable, Sendable {
    public let columns: UInt16
    public let rows: UInt16

    public init(columns: UInt16, rows: UInt16) {
        self.columns = max(1, columns)
        self.rows = max(1, rows)
    }
}

public struct CmuxTUIRenderEvent: Sendable {
    public enum Kind: UInt32, Sendable {
        case reset = 1
        case bytes = 2
        case resize = 3
        case ready = 4
        case exit = 5
    }

    public let kind: Kind
    public let geometry: CmuxTUITerminalGeometry
    public let payload: Data

    public init(kind: Kind, geometry: CmuxTUITerminalGeometry, payload: Data = Data()) {
        self.kind = kind
        self.geometry = geometry
        self.payload = payload
    }
}

public struct CmuxTUIRenderEventBatch: Sendable {
    public let events: [CmuxTUIRenderEvent]
    public let hasMore: Bool
    public let failure: CmuxTUIClientError?

    public init(
        events: [CmuxTUIRenderEvent],
        hasMore: Bool,
        failure: CmuxTUIClientError? = nil
    ) {
        self.events = events
        self.hasMore = hasMore
        self.failure = failure
    }
}

public struct CmuxTUITerminalSnapshot: Sendable {
    public let diagnostics: String
    public let didExit: Bool
}
