public import CmuxNextActions
public import CmuxNextDesign

/// A group color command's or Color choice's ball: the color it picks (cx-wqn5).
public struct PaletteBall: Hashable, Sendable {
    public var color: GroupColor
    /// Grey draws as content's mid grey (screens, spaces, profiles, workspaces), not a group's
    /// neutral step (`GroupColor.ballRGB(marksContent:)`).
    public var marksContent: Bool

    public init(_ color: GroupColor, marksContent: Bool) {
        self.color = color
        self.marksContent = marksContent
    }
}

/// The ball a group color command or a Color choice draws in place of its generic dot (cx-wqn5).
enum PaletteGroupColor {
    /// Groups draw grey as their neutral step; everything else marks content.
    private static let groupKinds: Set<Substring> = ["tabGroup", "workspaceGroup", "screenGroup"]

    /// `<kind>.color.<token>` commands: tab, workspace and screen groups, screens, spaces.
    static func ball(forAction id: ActionID) -> PaletteBall? {
        let parts = id.rawValue.split(separator: ".")
        guard parts.count == 3, parts[1] == "color", let color = GroupColor(rawValue: String(parts[2])) else { return nil }
        return PaletteBall(color, marksContent: !groupKinds.contains(parts[0]))
    }

    /// A `color` argument's choice for `action`.
    static func ball(action: ActionID, argument: String, value: String) -> PaletteBall? {
        guard argument == "color", let color = GroupColor(rawValue: value) else { return nil }
        let kind = action.rawValue.split(separator: ".").first ?? ""
        return PaletteBall(color, marksContent: !groupKinds.contains(kind))
    }
}
