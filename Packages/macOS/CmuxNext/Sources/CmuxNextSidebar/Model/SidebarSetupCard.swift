import Foundation

/// The "Finish setting up" card docked in the sidebar's bottom-left slot (Lawrence 2026-11-09, msg 25425: the
/// Set Up cmux card floated over Home's chat, "in the wrong place"; it goes to a compact card at the sidebar's
/// bottom left). A title with an x, a thin progress bar with "1 of N", one row per step (a dashed circle, or a
/// check on a dimmed row once done) and one full-width button that runs the next step. A row's click runs its
/// step: ``SidebarIntent/runSetupStep(_:)``; the x ``SidebarIntent/hideSetupCard``. The App sets it while
/// first-run setup is unfinished and not hidden. Text arrives localized.
public nonisolated struct SidebarSetupCard: Hashable, Sendable {
    /// One row.
    public struct Step: Hashable, Sendable {
        /// The step's id, sent back in ``SidebarIntent/runSetupStep(_:)``.
        public var id: String
        /// The row's text (an action: "Sign In to cmux").
        public var title: String
        /// Done: a check, the row dimmed, and no click.
        public var done: Bool
        /// The step runs (an install): a spinner in place of the circle, and no click.
        public var busy: Bool
        /// A click can run it now (false for a step cmux cannot do from here, which `help` explains).
        public var runnable: Bool
        /// The tooltip and VoiceOver help: what the step gives, or why it cannot run.
        public var help: String?

        public init(id: String, title: String, done: Bool = false, busy: Bool = false, runnable: Bool = true, help: String? = nil) {
            self.id = id
            self.title = title
            self.done = done
            self.busy = busy
            self.runnable = runnable
            self.help = help
        }
    }

    /// "Finish setting up".
    public var title: String
    public var steps: [Step]
    /// "1 of 4": steps done of steps shown.
    public var progressText: String
    /// The full-width button's text: the next step's action ("Sign In to Claude Code").
    public var buttonTitle: String?
    /// The step the button runs: the first runnable step not done; nil hides the button.
    public var buttonStep: String?
    /// The x's tooltip and VoiceOver label.
    public var closeLabel: String

    public init(title: String, steps: [Step], progressText: String, buttonTitle: String?, buttonStep: String?, closeLabel: String) {
        self.title = title
        self.steps = steps
        self.progressText = progressText
        self.buttonTitle = buttonTitle
        self.buttonStep = buttonStep
        self.closeLabel = closeLabel
    }

    /// Steps done.
    public var doneCount: Int { steps.count(where: \.done) }

    /// Done of shown, 0...1 (0 for no steps).
    public var fraction: Double { steps.isEmpty ? 0 : Double(doneCount) / Double(steps.count) }
}
