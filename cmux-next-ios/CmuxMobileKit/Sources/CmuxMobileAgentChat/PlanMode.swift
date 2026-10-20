import Foundation

/// The composer's Plan mode switch over the modes the agent advertises
/// (ACP `session/new` `modes`). Claude Code names it `plan`; an agent with no
/// plan mode (Codex) gets no switch, only the Permission mode picker.
public struct PlanModeSwitch: Hashable, Sendable {
    /// The advertised plan mode.
    public let planID: String
    /// Where turning the switch off goes: `default` when advertised, else the
    /// first other mode.
    public let exitID: String

    /// Nil when the agent advertises no plan mode, or nothing to leave it for.
    public init?(modes: [ACPMode]) {
        func isPlan(_ mode: ACPMode) -> Bool {
            mode.id.lowercased() == "plan" || mode.id.lowercased().hasSuffix("plan") || mode.name.lowercased() == "plan mode" || mode.name.lowercased() == "plan"
        }
        guard let plan = modes.first(where: isPlan) else { return nil }
        let others = modes.filter { !isPlan($0) }
        guard let exit = others.first(where: { $0.id == "default" }) ?? others.first else { return nil }
        planID = plan.id
        exitID = exit.id
    }

    public func isOn(currentModeID: String?) -> Bool { currentModeID == planID }

    /// The mode to switch to for `on`.
    public func mode(on: Bool) -> String { on ? planID : exitID }
}

extension AgentChatStore {
    /// The Plan mode switch for this session's advertised modes (nil: hidden).
    public var planModeSwitch: PlanModeSwitch? { PlanModeSwitch(modes: modes) }
}
