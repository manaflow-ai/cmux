public import Foundation

/// One session the preview may show, as the activity reports it.
public nonisolated struct ComputerUsePreviewCandidate: Equatable, Sendable {
    public var session: String
    public var agent: String?
    public var appName: String?
    public var lastAction: Date
    public var stopped: Bool

    public init(session: String, agent: String? = nil, appName: String? = nil, lastAction: Date, stopped: Bool = false) {
        self.session = session
        self.agent = agent
        self.appName = appName
        self.lastAction = lastAction
        self.stopped = stopped
    }
}

/// When the preview shows. Pure: the controller passes what it sees.
public nonisolated struct ComputerUsePreviewRules: Equatable, Sendable {
    /// How long after its last action an agent's preview stays up, so a short think between
    /// actions does not make it blink away.
    public var lingers: TimeInterval

    public init(lingers: TimeInterval = 15) {
        self.lingers = lingers
    }

    /// The session to preview in `surface`, the one the person looks at: the newest one of that
    /// surface that acted within ``lingers`` and is not stopped. Nil when the setting is off.
    public func session(for surface: ComputerUsePreviewSurface?, among candidates: [ComputerUsePreviewCandidate],
                        enabled: Bool, now: Date) -> ComputerUsePreviewCandidate? {
        guard enabled, let surface else { return nil }
        return candidates
            .filter { !$0.stopped && ComputerUsePreviewSurface(session: $0.session) == surface }
            .filter { now.timeIntervalSince($0.lastAction) < lingers }
            .max { $0.lastAction < $1.lastAction }
    }

    /// When the preview's session stops lingering (the controller looks again then), nil when it
    /// already has.
    public func lingersUntil(_ candidate: ComputerUsePreviewCandidate, now: Date) -> Date? {
        let end = candidate.lastAction.addingTimeInterval(lingers)
        return end > now ? end : nil
    }
}
