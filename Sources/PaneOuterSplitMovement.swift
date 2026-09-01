import CmuxPanes
import Foundation

extension PaneOuterSplitMovement {
    var shortcutAction: KeyboardShortcutSettings.Action {
        switch self {
        case .left: .movePaneToNewOuterSplitLeft
        case .right: .movePaneToNewOuterSplitRight
        case .above: .movePaneToNewOuterSplitAbove
        case .below: .movePaneToNewOuterSplitBelow
        }
    }

    init?(shortcutAction: KeyboardShortcutSettings.Action) {
        switch shortcutAction {
        case .movePaneToNewOuterSplitLeft: self = .left
        case .movePaneToNewOuterSplitRight: self = .right
        case .movePaneToNewOuterSplitAbove: self = .above
        case .movePaneToNewOuterSplitBelow: self = .below
        default: return nil
        }
    }

    var commandID: String {
        switch self {
        case .left: "palette.movePaneToNewOuterSplitLeft"
        case .right: "palette.movePaneToNewOuterSplitRight"
        case .above: "palette.movePaneToNewOuterSplitAbove"
        case .below: "palette.movePaneToNewOuterSplitBelow"
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
        case .left:
            String(
                localized: "shortcut.movePaneToNewOuterSplitLeft.label",
                defaultValue: "Move Pane to New Outer Split on Left"
            )
        case .right:
            String(
                localized: "shortcut.movePaneToNewOuterSplitRight.label",
                defaultValue: "Move Pane to New Outer Split on Right"
            )
        case .above:
            String(
                localized: "shortcut.movePaneToNewOuterSplitAbove.label",
                defaultValue: "Move Pane to New Outer Split Above"
            )
        case .below:
            String(
                localized: "shortcut.movePaneToNewOuterSplitBelow.label",
                defaultValue: "Move Pane to New Outer Split Below"
            )
        }
    }

    var keywords: [String] {
        switch self {
        case .left: ["move", "pane", "outer", "root", "split", "left"]
        case .right: ["move", "pane", "outer", "root", "split", "right"]
        case .above: ["move", "pane", "outer", "root", "split", "above", "up"]
        case .below: ["move", "pane", "outer", "root", "split", "below", "down"]
        }
    }
}
