import AppKit
import CmuxNextActions
import CmuxNextIcons
import CmuxNextPages
import CmuxNextSettings

extension PageDescriptor {
    /// The Keyboard Shortcuts editor (R59): cmux-page://cmux.keybindings/.
    static let keybindings = PageDescriptor(id: "cmux.keybindings", resource: "keybindings", namespaces: ["cmux.keybindings."],
                                            ownsSearchField: true)
}

extension InternalPageID {
    static let keybindings = InternalPageID(rawValue: "keybindings")
}

/// Owns the Keyboard Shortcuts page: a React page on CmuxNextPages whose
/// `cmux.keybindings.*` ops this app serves from the binding table
/// (`KeybindingsPageProvider`). One tab per window (`services.pages`).
@MainActor
final class KeybindingsPageService: InternalPageProvider {
    private unowned let services: AppServices

    init(services: AppServices) {
        self.services = services
    }

    /// Opens the page in the active window; automation (`focus` false)
    /// opens it without moving focus.
    func open(focus: Bool) throws {
        guard let window = services.windows.active, services.pages.show(.keybindings, in: window, focus: focus) != nil else {
            throw ActionFailure(message: RefusalStrings.noWindowOpen)
        }
    }

    var page: InternalPageID { .keybindings }
    var title: String { KeybindingStrings.pageTitle }
    var symbol: String { "keyboard" }
    var icon: IconName? { .keyboard }

    func makeView(for key: String, in window: WindowController?) -> NSView {
        let provider = KeybindingsPageProvider(services: services)
        let routes = [PageRoute(prefix: "cmux.keybindings.", provider: provider)]
        guard let page = PageWebView(descriptor: .keybindings, routes: routes) else { return NSView() }
        provider.pageWindow = { [weak page] in page?.window }
        return page
    }
}
