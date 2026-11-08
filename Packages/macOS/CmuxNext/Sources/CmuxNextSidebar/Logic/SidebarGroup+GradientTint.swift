public import CmuxNextDesign

extension SidebarGroup {
    /// What each group draws in under the gradient palette (`sidebar.groupPalette` `gradient`, Leo 2026-11-07: "imagine
    /// the gradients are just, like, based off of placement ... They're, like, dynamic"): every group with a palette
    /// color, in list order, takes the gradient's color at its place among them (``GroupGradient/place(_:of:)``), so
    /// the list always runs the whole gradient and a group that moves recolors. Nothing is stored: a group keeps its
    /// token, and another palette draws it again. A custom color a person picked keeps its own color, and a group with
    /// no color stays glass. Under any other palette, none (every group draws its own tint).
    /// - Parameters:
    ///   - groups: The list's groups, top first.
    ///   - palette: `sidebar.groupPalette`.
    ///   - gradient: `sidebar.groupGradient`.
    /// - Returns: The tint each placed group draws, by id.
    nonisolated public static func drawnTints(_ groups: [SidebarGroup], palette: GroupPalette,
                                              gradient: GroupGradient) -> [GroupID: GroupTint] {
        guard palette == .gradient else { return [:] }
        let placed = groups.filter { if case .palette = $0.tint { true } else { false } }
        var tints: [GroupID: GroupTint] = [:]
        tints.reserveCapacity(placed.count)
        for (index, group) in placed.enumerated() {
            tints[group.id] = gradientTint(gradient, at: GroupGradient.place(index, of: placed.count))
        }
        return tints
    }

    /// The gradient's color at `place` as a custom tint, in the 8-bit form a group's tint stores (`GroupTint.wire`), so
    /// a group given it reads back the same tint.
    nonisolated public static func gradientTint(_ gradient: GroupGradient, at place: Double) -> GroupTint {
        let rgb = gradient.rgb(at: place).withAlpha(1)
        return GroupTint(wire: rgb.description) ?? .custom(rgb)
    }
}
