import Foundation

/// The text of "Quit cmux?" (Resources/QuitConfirm.xcstrings): the question a
/// person's quit asks before it ends running work (`QuitRules.confirms`).
public struct QuitConfirmText: Equatable, Sendable {
    public var title: String
    /// One sentence per kind of loss, with its count.
    public var lines: [String]
    /// The button that quits (Return).
    public var quit: String

    public init(_ losses: QuitLosses) {
        title = String(localized: "quit.confirm.title", defaultValue: "Quit cmux?", table: "QuitConfirm", bundle: .module)
        quit = String(localized: "quit.confirm.quit", defaultValue: "Quit", table: "QuitConfirm", bundle: .module)
        let agents = String(format: String(localized: "quit.confirm.agents", defaultValue: "Working agents that will end: %lld.",
                                           table: "QuitConfirm", bundle: .module), losses.agents)
        let terminals = String(format: String(localized: "quit.confirm.terminals", defaultValue: "Open terminals that will end: %lld.",
                                              table: "QuitConfirm", bundle: .module), losses.terminals)
        lines = (losses.agents > 0 ? [agents] : []) + (losses.terminals > 0 ? [terminals] : [])
    }
}
