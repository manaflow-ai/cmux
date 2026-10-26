/// Who caused a model change (plans/cmux-next/chrome-parity/p06-scheduler.md, section C).
public enum ObservationCause: Sendable, Equatable {
    /// The person at this Mac: a key, a click, a local intent apply.
    case person
    /// Another of the person's frontends (the iPhone, the web app).
    case frontend
    /// The app itself, or a daemon too old to say.
    case program
    /// An agent, the CLI, MCP or another process.
    case automation
}

/// The class an observation's flush runs in.
public enum ObservationFlushClass: Sendable, Equatable {
    /// In the ``InputResponsePass`` while an input response is open, else as user-blocking work.
    case person
    /// ``MainWorkClass/visible``.
    case visible
    /// ``MainWorkClass/automation``.
    case automation
}

/// The cause in effect now and the person-cause epoch: the rule that gives a dirty observation its
/// flush class (p06-scheduler-025, p06-scheduler-206).
///
/// `withObservationTracking` calls `onChange` once, at the first change after the read, so an
/// observation knows only the cause of the change that made it dirty. A later change by the person
/// would never reach it. So every person change moves the epoch, and an observation whose mark's
/// epoch is behind the current one flushes as the person's ("automation, then the person on the
/// same property" is the person's). Otherwise its recorded cause decides: frontend and program are
/// visible, automation is automation.
///
/// ```swift
/// let causes = ObservationCauses()
/// causes.with(.person) { model.title = "typed" }   // onChange: queue.markDirty(observation)
/// causes.flushClass(of: mark)                       // .person
/// ```
@MainActor
public final class ObservationCauses {
    /// What an observation records when it becomes dirty.
    public struct Mark: Sendable, Equatable {
        /// The cause in effect when it became dirty.
        public let cause: ObservationCause
        /// The person-cause epoch then.
        public let personEpoch: UInt64
    }

    /// The cause of the change being applied now.
    public private(set) var current: ObservationCause
    /// Moves once per person change (``with(_:_:)`` with ``ObservationCause/person``).
    public private(set) var personEpoch: UInt64 = 0

    /// - Parameter current: The cause outside any ``with(_:_:)`` (default: the program's).
    public init(current: ObservationCause = .program) {
        self.current = current
    }

    /// Runs `change` with `cause` in effect, then restores the cause before it. A person change
    /// moves the epoch before it runs.
    public func with<T>(_ cause: ObservationCause, _ change: () throws -> T) rethrows -> T {
        let saved = current
        current = cause
        if cause == .person { personEpoch &+= 1 }
        defer { current = saved }
        return try change()
    }

    /// The mark of an observation that becomes dirty now.
    public func mark() -> Mark {
        Mark(cause: current, personEpoch: personEpoch)
    }

    /// The class the flush of an observation marked `mark` runs in now: person when its cause was
    /// or a person change came since, else its recorded cause's class.
    public func flushClass(of mark: Mark) -> ObservationFlushClass {
        if mark.personEpoch != personEpoch { return .person }
        switch mark.cause {
        case .person: return .person
        case .frontend, .program: return .visible
        case .automation: return .automation
        }
    }
}
