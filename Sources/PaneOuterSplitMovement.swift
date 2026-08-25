import Bonsplit
import Foundation

/// A direction in which the focused pane can be promoted to a new workspace
/// edge split.
enum PaneOuterSplitMovement: CaseIterable, Hashable, Sendable {
    case left
    case right
    case above
    case below

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

    var orientation: SplitOrientation {
        switch self {
        case .left, .right: .horizontal
        case .above, .below: .vertical
        }
    }

    /// Whether the promoted pane is inserted before the remaining root tree.
    var insertFirst: Bool {
        switch self {
        case .left, .above: true
        case .right, .below: false
        }
    }
}
