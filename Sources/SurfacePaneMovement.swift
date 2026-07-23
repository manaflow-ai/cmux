import Foundation

/// A destination for moving the active surface into an existing pane.
enum SurfacePaneMovement: CaseIterable, Hashable, Sendable {
    case previous
    case next
    case left
    case right
    case up
    case down

    var shortcutAction: KeyboardShortcutSettings.Action {
        switch self {
        case .previous: .moveSurfaceToPreviousPane
        case .next: .moveSurfaceToNextPane
        case .left: .moveSurfaceToPaneLeft
        case .right: .moveSurfaceToPaneRight
        case .up: .moveSurfaceToPaneUp
        case .down: .moveSurfaceToPaneDown
        }
    }

    init?(shortcutAction: KeyboardShortcutSettings.Action) {
        switch shortcutAction {
        case .moveSurfaceToPreviousPane: self = .previous
        case .moveSurfaceToNextPane: self = .next
        case .moveSurfaceToPaneLeft: self = .left
        case .moveSurfaceToPaneRight: self = .right
        case .moveSurfaceToPaneUp: self = .up
        case .moveSurfaceToPaneDown: self = .down
        default: return nil
        }
    }

    var commandID: String {
        switch self {
        case .previous: "palette.moveSurfaceToPreviousPane"
        case .next: "palette.moveSurfaceToNextPane"
        case .left: "palette.moveSurfaceToPaneLeft"
        case .right: "palette.moveSurfaceToPaneRight"
        case .up: "palette.moveSurfaceToPaneUp"
        case .down: "palette.moveSurfaceToPaneDown"
        }
    }

    init?(commandID: String) {
        guard let movement = Self.allCases.first(where: { $0.commandID == commandID }) else {
            return nil
        }
        self = movement
    }

    var title: String {
        switch self {
        case .previous:
            String(
                localized: "shortcut.moveSurfaceToPreviousPane.label",
                defaultValue: "Move Surface to Previous Pane"
            )
        case .next:
            String(
                localized: "shortcut.moveSurfaceToNextPane.label",
                defaultValue: "Move Surface to Next Pane"
            )
        case .left:
            String(
                localized: "shortcut.moveSurfaceToPaneLeft.label",
                defaultValue: "Move Surface to Pane on Left"
            )
        case .right:
            String(
                localized: "shortcut.moveSurfaceToPaneRight.label",
                defaultValue: "Move Surface to Pane on Right"
            )
        case .up:
            String(
                localized: "shortcut.moveSurfaceToPaneUp.label",
                defaultValue: "Move Surface to Pane Above"
            )
        case .down:
            String(
                localized: "shortcut.moveSurfaceToPaneDown.label",
                defaultValue: "Move Surface to Pane Below"
            )
        }
    }

    var keywords: [String] {
        switch self {
        case .previous: ["move", "surface", "tab", "previous", "pane"]
        case .next: ["move", "surface", "tab", "next", "pane"]
        case .left: ["move", "surface", "tab", "left", "pane"]
        case .right: ["move", "surface", "tab", "right", "pane"]
        case .up: ["move", "surface", "tab", "up", "above", "upper", "pane"]
        case .down: ["move", "surface", "tab", "down", "below", "lower", "pane"]
        }
    }
}
