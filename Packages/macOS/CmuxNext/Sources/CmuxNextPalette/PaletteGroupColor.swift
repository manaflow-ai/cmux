public import CmuxNextActions
public import CmuxNextDesign

/// A group color command's or Color choice's ball: the color it picks (cx-wqn5).
public struct PaletteBall: Hashable, Sendable {
    public var color: GroupColor

    public init(_ color: GroupColor) {
        self.color = color
    }
}

/// The ball a group color command or a Color choice draws in place of its generic dot (cx-wqn5).
enum PaletteGroupColor {
    /// `<kind>.color.<token>` commands: tab, workspace and screen groups, screens, spaces.
    static func ball(forAction id: ActionID) -> PaletteBall? {
        let parts = id.rawValue.split(separator: ".")
        guard parts.count == 3, parts[1] == "color", let color = GroupColor(rawValue: String(parts[2])) else { return nil }
        return PaletteBall(color)
    }

    /// A `color` argument's choice for `action`.
    static func ball(action: ActionID, argument: String, value: String) -> PaletteBall? {
        guard argument == "color", let color = GroupColor(rawValue: value) else { return nil }
        return PaletteBall(color)
    }
}
