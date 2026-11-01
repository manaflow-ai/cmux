import AppKit
/// The small, customizable action strip cmux contributes to a Mac Touch Bar.
/// Actions go through the same registry as keyboard shortcuts and menus, so
/// target resolution and focus rules remain shared with the rest of the app.
final class CmuxTouchBar: NSObject, NSTouchBarDelegate {
    static let touchBarIdentifier = NSTouchBar.CustomizationIdentifier("com.cmux.next.touchbar")

    private enum Action {
        static let previousWorkspace = "prevSidebarTab"
        static let nextWorkspace = "nextSidebarTab"
        static let previousPane = "focusPreviousPane"
        static let nextPane = "focusNextPane"
        static let stopAgent = "agentPane.stopTurn"
    }

    private let perform: (String) -> Bool
    let touchBar: NSTouchBar

    init(perform: @escaping (String) -> Bool) {
        self.perform = perform
        touchBar = NSTouchBar()
        super.init()
        touchBar.delegate = self
        touchBar.customizationIdentifier = Self.touchBarIdentifier
        touchBar.defaultItemIdentifiers = [
            Self.itemIdentifier(Action.previousWorkspace),
            Self.itemIdentifier(Action.nextWorkspace),
            .flexibleSpace,
            Self.itemIdentifier(Action.previousPane),
            Self.itemIdentifier(Action.nextPane),
            .flexibleSpace,
            Self.itemIdentifier(Action.stopAgent),
        ]
        touchBar.customizationAllowedItemIdentifiers = touchBar.defaultItemIdentifiers
    }

    static func itemIdentifier(_ action: String) -> NSTouchBarItem.Identifier {
        NSTouchBarItem.Identifier("com.cmux.next.touchbar.\(action)")
    }

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        let action: (id: String, image: String, label: String)?
        switch identifier {
        case Self.itemIdentifier(Action.previousWorkspace):
            action = (Action.previousWorkspace, "chevron.left", "Previous Workspace")
        case Self.itemIdentifier(Action.nextWorkspace):
            action = (Action.nextWorkspace, "chevron.right", "Next Workspace")
        case Self.itemIdentifier(Action.previousPane):
            action = (Action.previousPane, "arrow.left", "Previous Pane")
        case Self.itemIdentifier(Action.nextPane):
            action = (Action.nextPane, "arrow.right", "Next Pane")
        case Self.itemIdentifier(Action.stopAgent):
            action = (Action.stopAgent, "stop.fill", "Stop Agent Turn")
        default:
            action = nil
        }
        guard let action else { return nil }
        let item = NSCustomTouchBarItem(identifier: identifier)
        let button = NSButton(
            image: NSImage(systemSymbolName: action.image, accessibilityDescription: action.label) ?? NSImage(),
            target: self,
            action: #selector(actionPressed(_:))
        )
        button.imagePosition = .imageOnly
        button.bezelStyle = .texturedRounded
        button.toolTip = action.label
        button.setAccessibilityLabel(action.label)
        button.identifier = NSUserInterfaceItemIdentifier(action.id)
        item.view = button
        return item
    }

    @objc private func actionPressed(_ sender: NSButton) {
        guard let action = sender.identifier?.rawValue else { return }
        _ = perform(action)
    }
}
