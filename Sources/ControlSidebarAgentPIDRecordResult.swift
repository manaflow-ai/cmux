/// Whether an exact agent process generation was admitted by its panel owner.
nonisolated struct ControlSidebarAgentPIDRecordResult {
    let accepted: Bool
    let replacedOtherRuntime: Bool

    static let rejected = Self(
        accepted: false,
        replacedOtherRuntime: false
    )

    static func accepted(replacedOtherRuntime: Bool) -> Self {
        Self(
            accepted: true,
            replacedOtherRuntime: replacedOtherRuntime
        )
    }
}
