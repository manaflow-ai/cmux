import AppKit
import CmuxNextActions

/// List navigation (R85): Next Item / Previous Item move the selection of
/// the focused list-like control. The key dispatcher runs them only where
/// `listFocus` holds; they hand the key window's first responder a Down or
/// Up arrow, which every list (a page's combobox or menu, the sidebar list
/// and its search field) already understands, so no list needs its own
/// Ctrl-N/P/J/K code.
enum ListHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let services = context.services
        registry.bind("list.next", run: { _ in try arrow(down: true, services: services) })
        registry.bind("list.previous", run: { _ in try arrow(down: false, services: services) })
    }

    @MainActor
    static func arrow(down: Bool, services: AppServices) throws {
        guard let window = services.keyWindowSource(),
              let event = arrowEvent(down: down, windowNumber: window.windowNumber) else {
            throw ActionFailure(message: RefusalStrings.noWindowOpen)
        }
        // Straight to the window: the dispatcher already decided this key.
        window.sendEvent(event)
    }

    /// A Down (keyCode 125) or Up (126) arrow key-down, as the keyboard sends it.
    nonisolated static func arrowEvent(down: Bool, windowNumber: Int) -> NSEvent? {
        let scalar = UnicodeScalar(down ? NSDownArrowFunctionKey : NSUpArrowFunctionKey).map(String.init) ?? ""
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.numericPad, .function],
                                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: windowNumber, context: nil,
                                characters: scalar, charactersIgnoringModifiers: scalar, isARepeat: false,
                                keyCode: down ? 125 : 126)
    }
}
