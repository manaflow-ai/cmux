import CmuxHomeCore
import Foundation

/// The running Chief turn's steps as Home saw them: one per distinct "working on"
/// line (`run.activity`), each from its start to the next one's. The owner sends
/// only the newest line, so this is the client's own record of the turn so far; a
/// line that sharpens with the same start (a tool's input arrived) stays one step.
struct HomeTurnSteps: Equatable {
    struct Step: Equatable {
        var line: String
        var start: Date
        /// The next step's start; nil while this one runs.
        var end: Date?
    }

    private(set) var steps: [Step] = []

    /// At most this many steps are kept (the oldest go first); the turn's start stays.
    static let limit = 200
    private var started: Date?

    mutating func record(_ activity: HomeLiveActivity) {
        if let last = steps.last {
            if last.start == activity.since {
                // The same work, a sharper line ("Telling an agent" -> "Telling a31").
                steps.update(at: steps.count - 1) { $0.line = activity.line }
                return
            }
            if activity.since < last.start {
                // Older than the newest step: a new run's clock (or a resend of an old frame). Start over.
                self = HomeTurnSteps()
            } else {
                steps.update(at: steps.count - 1) { $0.end = activity.since }
            }
        }
        if started == nil { started = activity.since }
        steps.append(Step(line: activity.line, start: activity.since, end: nil))
        if steps.count > Self.limit { steps.removeFirst(steps.count - Self.limit) }
    }

    func details(now: Date) -> HomeTurnDetails {
        HomeTurnDetails(
            steps: steps.map { step in
                HomeTurnDetails.Row(line: step.line, duration: (step.end ?? now).timeIntervalSince(step.start),
                                    running: step.end == nil)
            },
            total: started.map { now.timeIntervalSince($0) } ?? 0)
    }
}

/// What the status line's details popover shows: the turn's steps in order, each with
/// how long it took (the running one: so far), and the turn's time so far.
struct HomeTurnDetails: Equatable {
    struct Row: Equatable {
        var line: String
        var duration: TimeInterval
        var running: Bool
    }

    var steps: [Row]
    var total: TimeInterval
}
