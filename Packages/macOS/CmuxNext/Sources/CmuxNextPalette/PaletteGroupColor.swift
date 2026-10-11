import CmuxNextActions
import CmuxNextDesign

/// The ball a group color command or a Color choice draws in place of its generic dot (cx-wqn5):
/// the color it picks, in the theme, as the group editors' swatches show it.
enum PaletteGroupColor {
    /// `<kind>.color.<token>` commands: tab, workspace and screen groups, screens, profiles.
    static func swatches(forAction id: ActionID) -> [ThemeRGB] {
        let parts = id.rawValue.split(separator: ".")
        guard parts.count == 3, parts[1] == "color" else { return [] }
        return swatches(GroupColor(rawValue: String(parts[2])))
    }

    /// A `color` argument's choices.
    static func swatches(argument: String, value: String) -> [ThemeRGB] {
        argument == "color" ? swatches(GroupColor(rawValue: value)) : []
    }

    private static func swatches(_ color: GroupColor?) -> [ThemeRGB] {
        color.map { [$0.ballRGB] } ?? []
    }
}
