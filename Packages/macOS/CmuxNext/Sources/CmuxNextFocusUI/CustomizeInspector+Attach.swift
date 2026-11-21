public import AppKit
public import CmuxNextActions

extension CustomizeInspector {
    /// The Customize Inspector of `window`, whose buttons run registered actions: Change This… is
    /// `customize.open` with the element, Reset is `customize.reset` with it, so the inspector does
    /// nothing the palette and the CLI cannot. The window's shortcut hints drive it (`holdChanged`).
    public convenience init(window: NSWindow, registry: ActionRegistry) {
        self.init(window: window, actions: Self.actions(registry))
    }

    /// What the buttons run: the element's two registered actions.
    public static func actions(_ registry: ActionRegistry) -> Actions {
        Actions(change: { [weak registry] element in
            _ = registry?.perform(ActionID(rawValue: CustomizeElement.openActionID),
                                  invocation: ActionInvocation(arguments: ["element": .string(element.id)]))
        }, reset: { [weak registry] element in
            _ = registry?.perform(ActionID(rawValue: CustomizeElement.resetActionID),
                                  invocation: ActionInvocation(arguments: ["element": .string(element.id)]))
        })
    }
}
