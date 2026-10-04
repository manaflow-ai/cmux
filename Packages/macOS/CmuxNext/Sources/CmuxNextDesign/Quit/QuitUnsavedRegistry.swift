import Foundation

/// RED STUB (R96 quit hook): the registry API with no behavior yet.
@MainActor
public final class QuitUnsavedRegistry {
    public static let shared = QuitUnsavedRegistry()
    public static let maxDeadline: Duration = .seconds(30)

    public init(clock: any Clock<Duration> = ContinuousClock(), drafts: RecoveryDraftStore? = .shared) {}

    @discardableResult
    public func register(_ participant: any QuitUnsavedParticipant) -> QuitUnsavedRegistration { QuitUnsavedRegistration() }

    public func unsaved() -> [any QuitUnsavedParticipant] { [] }

    public func save(_ participants: [any QuitUnsavedParticipant], deadlineCap: Duration? = nil,
                     saving: (([String]) -> Void)? = nil) async -> [QuitFlushOutcome] { [] }

    public func discard(_ participants: [any QuitUnsavedParticipant]) async {}
}

@MainActor
public final class QuitUnsavedRegistration {
    public func cancel() {}
}
