import Foundation

/// Localized strings for the layout module (Resources/Localizable.xcstrings, en + ja).
enum LayoutStrings {
    static var dividerAccessibility: String {
        String(localized: "layout.divider.accessibility", defaultValue: "Split Divider", bundle: .module)
    }
    static var columnEdgeAccessibility: String {
        String(localized: "layout.columnEdge.accessibility", defaultValue: "Column Width", bundle: .module)
    }
    static var rowEdgeAccessibility: String {
        String(localized: "layout.rowEdge.accessibility", defaultValue: "Row Height", bundle: .module)
    }
    // Divider drag modes (plans/cmux-next/resize-modifiers.md), shown in a toast while a key is held.
    static var resizeModePush: String {
        String(localized: "layout.resizeMode.push", defaultValue: "⌥ Push: the column grows and moves the columns after it", bundle: .module)
    }
    static var resizeModeTrade: String {
        String(localized: "layout.resizeMode.trade", defaultValue: "⌥ Trade: the width comes from the next column", bundle: .module)
    }
    static var resizeModeAllColumns: String {
        String(localized: "layout.resizeMode.allColumns", defaultValue: "⌘ All columns: every column takes this width", bundle: .module)
    }
    static var resizeModeEven: String {
        String(localized: "layout.resizeMode.even", defaultValue: "⌘ Even: the panes on each side stay equal", bundle: .module)
    }
    static var resizeModeSnap: String {
        String(localized: "layout.resizeMode.snap", defaultValue: "⇧ Snap: halves and thirds only", bundle: .module)
    }
    static var resizeModeFine: String {
        String(localized: "layout.resizeMode.fine", defaultValue: "⌃ Fine: a quarter of the pointer’s speed", bundle: .module)
    }
    static var stripScrollbarAccessibility: String {
        String(localized: "layout.stripScrollbar.accessibility", defaultValue: "Column Strip Scroll Bar", bundle: .module)
    }
    static var dropNewColumn: String {
        String(localized: "layout.drop.newColumn", defaultValue: "New Column", bundle: .module)
    }
    static var dropSplitLeft: String {
        String(localized: "layout.drop.splitLeft", defaultValue: "Split Left", bundle: .module)
    }
    static var dropSplitRight: String {
        String(localized: "layout.drop.splitRight", defaultValue: "Split Right", bundle: .module)
    }
    static var dropSplitUp: String {
        String(localized: "layout.drop.splitUp", defaultValue: "Split Up", bundle: .module)
    }
    static var dropSplitDown: String {
        String(localized: "layout.drop.splitDown", defaultValue: "Split Down", bundle: .module)
    }
    static var dropDockTop: String {
        String(localized: "layout.drop.dockTop", defaultValue: "Dock at Top", bundle: .module)
    }
    static var dropDockBottom: String {
        String(localized: "layout.drop.dockBottom", defaultValue: "Dock at Bottom", bundle: .module)
    }
    static var dropDockLeft: String {
        String(localized: "layout.drop.dockLeft", defaultValue: "Dock at Left", bundle: .module)
    }
    static var dropDockRight: String {
        String(localized: "layout.drop.dockRight", defaultValue: "Dock at Right", bundle: .module)
    }
    static var dropMoveHere: String {
        String(localized: "layout.drop.moveHere", defaultValue: "Move Here", bundle: .module)
    }

    static func label(for target: DropTarget) -> String {
        switch target {
        case .newColumn: dropNewColumn
        case let .newDock(_, edge):
            switch edge {
            case .left: dropDockLeft
            case .right: dropDockRight
            case .top: dropDockTop
            case .bottom: dropDockBottom
            }
        case let .pane(_, zone):
            switch zone {
            case .left: dropSplitLeft
            case .right: dropSplitRight
            case .top: dropSplitUp
            case .bottom: dropSplitDown
            case .center: dropMoveHere
            }
        }
    }
}
