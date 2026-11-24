public import CmuxNextDesign
public import CmuxTheme

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
    /// Under the pictorial palette the same holds with the desktop picture's bands (`wallpaper`, top first) in place
    /// of the gradient (Leo 2026-11-07: "have hints of your background wallpaper ... like a pictorial group"); before
    /// the picture is sampled, none (the groups draw the wallpaper palette).
    nonisolated public static func drawnTints(_ groups: [SidebarGroup], palette: GroupPalette, gradient: GroupGradient,
                                              wallpaper: [WallpaperTint] = []) -> [GroupID: GroupTint] {
        let color: (Double) -> ThemeRGB
        switch palette {
        case .gradient: color = { gradient.rgb(at: $0) }
        case .pictorial where !wallpaper.isEmpty: color = { GroupColor.pictorialRGB(wallpaper, at: $0) }
        default: return [:]
        }
        let placed = groups.filter { if case .palette = $0.tint { true } else { false } }
        var tints: [GroupID: GroupTint] = [:]
        tints.reserveCapacity(placed.count)
        for (index, group) in placed.enumerated() {
            tints[group.id] = storedForm(color(GroupGradient.place(index, of: placed.count)))
        }
        return tints
    }

    /// The gradient's color at `place` as a custom tint, in the 8-bit form a group's tint stores (`GroupTint.wire`), so
    /// a group given it reads back the same tint.
    nonisolated public static func gradientTint(_ gradient: GroupGradient, at place: Double) -> GroupTint {
        storedForm(gradient.rgb(at: place))
    }

    /// `rgb` as a custom tint in its stored 8-bit form.
    nonisolated static func storedForm(_ rgb: ThemeRGB) -> GroupTint {
        let opaque = rgb.withAlpha(1)
        return GroupTint(wire: opaque.description) ?? .custom(opaque)
    }
}
