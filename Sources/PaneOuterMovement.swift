import Bonsplit
import Foundation

/// A semantic workspace edge where the focused pane becomes a new root child.
enum PaneOuterMovement: CaseIterable, Hashable, Sendable {
    case left
    case right
    case above
    case below

    var shortcutAction: KeyboardShortcutSettings.Action {
        switch self {
        case .left: .movePaneToOuterLeft
        case .right: .movePaneToOuterRight
        case .above: .movePaneToOuterTop
        case .below: .movePaneToOuterBottom
        }
    }

    var commandID: String {
        "palette.\(shortcutAction.rawValue)"
    }

    init?(commandID: String) {
        guard let movement = Self.allCases.first(where: {
            $0.commandID == commandID
        }) else {
            return nil
        }
        self = movement
    }

    var title: String {
        switch self {
        case .left:
            String(
                localized: "shortcut.movePaneToOuterLeft.label",
                defaultValue: "Move Pane to New Outer Split on Left"
            )
        case .right:
            String(
                localized: "shortcut.movePaneToOuterRight.label",
                defaultValue: "Move Pane to New Outer Split on Right"
            )
        case .above:
            String(
                localized: "shortcut.movePaneToOuterTop.label",
                defaultValue: "Move Pane to New Outer Split Above"
            )
        case .below:
            String(
                localized: "shortcut.movePaneToOuterBottom.label",
                defaultValue: "Move Pane to New Outer Split Below"
            )
        }
    }

    var keywords: [String] {
        switch self {
        case .left: ["move", "pane", "outer", "root", "split", "left"]
        case .right: ["move", "pane", "outer", "root", "split", "right"]
        case .above: ["move", "pane", "outer", "root", "split", "above", "top"]
        case .below: ["move", "pane", "outer", "root", "split", "below", "bottom"]
        }
    }

    var rootSplitEdge: RootSplitEdge {
        switch self {
        case .left: .left
        case .right: .right
        case .above: .above
        case .below: .below
        }
    }
}
