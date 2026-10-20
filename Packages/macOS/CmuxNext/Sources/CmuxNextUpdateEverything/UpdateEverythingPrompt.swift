public import Foundation

/// The confirmation's words for a plan: a line per machine naming what changes there, the
/// running threads that restart, and the "Continue threads after restarts" check box (on).
///
/// ```swift
/// let prompt = UpdateEverythingPrompt(plan)
/// // prompt.lines: ["This Mac: cmux NEXT 0.9.12 → 0.9.13", "devbox: cmux abc123 → def456, Codex 0.40 → 0.41", …]
/// ```
public nonisolated struct UpdateEverythingPrompt: Sendable, Equatable {
    public var title: String
    /// One line per machine, then the interrupted-thread line when threads restart.
    public var lines: [String]
    /// The check box's title.
    public var continueThreads: String
    /// The confirm button's title.
    public var button: String

    /// - Parameter plan: The plan to describe.
    public init(_ plan: UpdateEverythingPlan) {
        title = UpdateEverythingStrings.title
        var lines = plan.machines.map(Self.line)
        let threads = plan.interruptedThreads
        if threads > 0 { lines.append(UpdateEverythingStrings.threadsRestart(threads)) }
        if plan.relaunches { lines.append(UpdateEverythingStrings.relaunches) }
        self.lines = lines
        continueThreads = UpdateEverythingStrings.continueThreads
        button = UpdateEverythingStrings.button
    }

    /// `devbox: cmux abc123 → def456, Codex 0.40 → 0.41`, or `devbox: up to date`.
    static func line(_ machine: UpdateEverythingMachine) -> String {
        let changes = machine.changes.map(change).joined(separator: ", ")
        return UpdateEverythingStrings.machineLine(machine.name, changes.isEmpty ? UpdateEverythingStrings.upToDate : changes)
    }

    static func change(_ change: UpdateEverythingChange) -> String {
        switch (change.from, change.to) {
        case let (from?, to?): "\(change.name) \(from) → \(to)"
        case let (nil, to?): "\(change.name) → \(to)"
        default: change.name
        }
    }
}
