import Foundation

/// The result of one participant's save.
public nonisolated struct QuitFlushOutcome: Equatable, Sendable {
    public enum Result: Equatable, Sendable {
        case saved
        case failed(String)
        case timedOut
    }

    public var id: String
    public var title: String
    public var result: Result

    public init(id: String, title: String, result: Result) {
        self.id = id
        self.title = title
        self.result = result
    }

    /// The reason a failed or timed-out save shows.
    public var reason: String? {
        switch result {
        case .saved: nil
        case .failed(let reason): reason
        case .timedOut: QuitFlushStrings.timedOut
        }
    }
}

nonisolated enum QuitFlushStrings {
    static var conflict: String { String(localized: "quitFlush.conflict", defaultValue: "%@ changed on disk", bundle: .module) }
    static var readOnly: String { String(localized: "quitFlush.readOnly", defaultValue: "%@ is read-only", bundle: .module) }
    static var timedOut: String { String(localized: "quitFlush.timedOut", defaultValue: "Saving did not finish in time", bundle: .module) }
}
