import Foundation

/// Localized strings for the layout module (Resources/Localizable.xcstrings, en + ja).
enum LayoutStrings {
    static var dividerAccessibility: String {
        String(localized: "layout.divider.accessibility", defaultValue: "Split Divider", bundle: .module)
    }
    static var columnEdgeAccessibility: String {
        String(localized: "layout.columnEdge.accessibility", defaultValue: "Column Width", bundle: .module)
    }
    static var stripScrollbarAccessibility: String {
        String(localized: "layout.stripScrollbar.accessibility", defaultValue: "Column Strip Scroll Bar", bundle: .module)
    }
    static func screenFallbackName(_ number: Int) -> String {
        String(localized: "layout.screen.fallbackName", defaultValue: "Screen \(number)", bundle: .module)
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
    static var dropMoveHere: String {
        String(localized: "layout.drop.moveHere", defaultValue: "Move Here", bundle: .module)
    }

    static func label(for target: DropTarget) -> String {
        switch target {
        case .newColumn: dropNewColumn
        case let .newDock(_, edge): edge == .top ? dropDockTop : dropDockBottom
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
