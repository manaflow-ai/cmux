import Foundation

/// Whether computer use is set up on this Mac, for the composer's `@computer-use` (CMUX-682,
/// Lawrence and Lucas 2026-11-20: "@computer use" is always in the @ menu; picking it when it is
/// not set up says so in the chat, with Set Up Computer Use). The App reads its one
/// `ComputerUseSetup`; the page asks with `chat.computerUse.state` and gets `{state}`.
public nonisolated enum AgentPaneComputerUseState: String, Sendable, Equatable {
    /// The helper answered and holds Accessibility and Screen Recording.
    case ready
    /// The helper is starting or has not answered yet: not working yet, so the page holds the send.
    case starting
    /// Off, missing a grant, failed or of another version: Set Up Computer Use fixes it.
    case needsSetup = "needs_setup"
    /// The organization turned computer use off: no setup can help.
    case disabled

    /// The state of the App's Computer Use Setup: its phase (`ComputerUseSetup.Phase`'s raw value)
    /// and whether the helper holds both Accessibility and Screen Recording.
    public init(phase: String, granted: Bool) {
        switch phase {
        case "ready": self = granted ? .ready : .needsSetup
        case "starting": self = .starting
        case "disabled_by_policy": self = .disabled
        default: self = .needsSetup
        }
    }

    /// The action the page runs for Set Up Computer Use (`action.run`): the onboarding step that
    /// turns computer use on and asks for both grants (AgentHandlers, `palette.computerUse.setup`).
    public static let setupAction = "palette.computerUse.setup"

    /// `chat.computerUse.state`'s reply; unsupported when the App gives no answer (a test host).
    @MainActor static func reply(_ state: AgentPaneComputerUseState?) -> [String: Any] {
        guard let state else { return AgentPaneModel.unsupported("chat.computerUse.state") }
        return AgentPaneReply.success(["state": state.rawValue])
    }
}
