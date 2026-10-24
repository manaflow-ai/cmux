import CmuxNextSettings
import CmuxNextCompat
import CmuxNextDaemon

/// Whether a request's work started, decided exactly once, so a timeout can
/// say `not_run` (the work never started and never will) or `in_progress`
/// (it started and may still apply; plans/cmux-next/state-ownership.md 4.4).
public final class ControlCallProgress: Sendable {
    private enum Phase {
        case pending
        case started
        case abandoned
    }

    private let phase = Mutex(Phase.pending)
    /// The `action.run` command scope, for its stage log at a timeout.
    private let scope = Mutex<DaemonCommandScope?>(nil)

    /// Keeps `scope` for ``stageLog`` and returns it.
    func track(_ scope: DaemonCommandScope) -> DaemonCommandScope {
        self.scope.withLock { $0 = scope }
        return scope
    }

    /// The tracked scope's stage log (`DaemonCommandScope.stageLog`).
    var stageLog: [String]? { scope.withLock { $0 }?.stageLog }

    public init() {}

    /// Claims the start. False when the request already answered `not_run`:
    /// the caller must then not run the work.
    public func begin() -> Bool {
        phase.withLock { phase in
            switch phase {
            case .pending:
                phase = .started
                return true
            case .started: return true
            case .abandoned: return false
            }
        }
    }

    /// At a timeout: true when the work never started (it now never will).
    public func abandonIfPending() -> Bool {
        phase.withLock { phase in
            guard phase == .pending else { return phase == .abandoned }
            phase = .abandoned
            return true
        }
    }

    public var hasStarted: Bool { phase.withLock { $0 == .started } }
}

extension ControlError {
    /// This error with `data.not_run` and `data.state` set: a `busy` or a
    /// timeout before the work started is `not_run` (safe to retry); one
    /// after it started is `in_progress` (a later step of the request, such as
    /// an `action.batch` transaction after earlier ones applied, found the
    /// queue full or expired). An error that already says `not_run` keeps it
    /// (an idempotent join whose run never started, a batch cut short).
    func annotated(progress: ControlCallProgress) -> ControlError {
        let notRun: Bool
        switch code {
        // A busy queue never ran this step, but an earlier step of the request may have applied.
        case "busy": notRun = data?["not_run"]?.boolValue ?? !progress.hasStarted
        case "timeout": notRun = data?["not_run"]?.boolValue ?? progress.abandonIfPending()
        default: return self
        }
        var error = self
        var members = data?.objectValue ?? [:]
        members["not_run"] = .bool(notRun)
        members["state"] = .string(notRun ? "not_run" : "in_progress")
        if code == "timeout", let log = progress.stageLog { members["waiting_on"] = .array(log.map(JSONValue.string)) }
        error.data = .object(members)
        return error
    }
}
