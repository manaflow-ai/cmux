import Foundation

/// Localized strings for the layout module (Resources/Localizable.xcstrings, en + ja).
enum LayoutStrings {
    static var dividerAccessibility: String {
        String(localized: "layout.divider.accessibility", defaultValue: "Split Divider", bundle: .l10n)
    }
    static var columnEdgeAccessibility: String {
        String(localized: "layout.columnEdge.accessibility", defaultValue: "Column Width", bundle: .l10n)
    }
    static var rowEdgeAccessibility: String {
        String(localized: "layout.rowEdge.accessibility", defaultValue: "Row Height", bundle: .l10n)
    }
    // Divider drag modes (plans/cmux-next/resize-modifiers.md), shown in a toast while a key is held.
    static var resizeModePush: String {
        String(localized: "layout.resizeMode.push", defaultValue: "⌥ Push: the column grows and moves the columns after it", bundle: .l10n)
    }
    static var resizeModeTrade: String {
        String(localized: "layout.resizeMode.trade", defaultValue: "⌥ Trade: the width comes from the next column", bundle: .l10n)
    }
    static var resizeModeAllColumns: String {
        String(localized: "layout.resizeMode.allColumns", defaultValue: "⌘ All columns: every column takes this width", bundle: .l10n)
    }
    static var resizeModeEven: String {
        String(localized: "layout.resizeMode.even", defaultValue: "⌘ Even: the panes on each side stay equal", bundle: .l10n)
    }
    static var resizeModeSnap: String {
        String(localized: "layout.resizeMode.snap", defaultValue: "⇧ Snap: halves and thirds only", bundle: .l10n)
    }
    static var resizeModeFine: String {
        String(localized: "layout.resizeMode.fine", defaultValue: "⌃ Fine: a quarter of the pointer’s speed", bundle: .l10n)
    }
    static var stripScrollbarAccessibility: String {
        String(localized: "layout.stripScrollbar.accessibility", defaultValue: "Column Strip Scroll Bar", bundle: .l10n)
    }
    static var dropNewColumn: String {
        String(localized: "layout.drop.newColumn", defaultValue: "New Column", bundle: .l10n)
    }
    static var dropSplitLeft: String {
        String(localized: "layout.drop.splitLeft", defaultValue: "Split Left", bundle: .l10n)
    }
    static var dropSplitRight: String {
        String(localized: "layout.drop.splitRight", defaultValue: "Split Right", bundle: .l10n)
    }
    static var dropSplitUp: String {
        String(localized: "layout.drop.splitUp", defaultValue: "Split Up", bundle: .l10n)
    }
    static var dropSplitDown: String {
        String(localized: "layout.drop.splitDown", defaultValue: "Split Down", bundle: .l10n)
    }
    static var dropDockTop: String {
        String(localized: "layout.drop.dockTop", defaultValue: "Dock at Top", bundle: .l10n)
    }
    static var dropDockBottom: String {
        String(localized: "layout.drop.dockBottom", defaultValue: "Dock at Bottom", bundle: .l10n)
    }
    static var dropDockLeft: String {
        String(localized: "layout.drop.dockLeft", defaultValue: "Dock at Left", bundle: .l10n)
    }
    static var dropDockRight: String {
        String(localized: "layout.drop.dockRight", defaultValue: "Dock at Right", bundle: .l10n)
    }
    static var dropMoveHere: String {
        String(localized: "layout.drop.moveHere", defaultValue: "Move Here", bundle: .l10n)
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
