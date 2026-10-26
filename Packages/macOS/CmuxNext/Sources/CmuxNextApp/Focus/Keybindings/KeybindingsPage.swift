import AppKit
import CmuxNextActions
import CmuxNextHibernation
import CmuxNextIcons
import CmuxNextPages
import CmuxNextSettings

extension PageDescriptor {
    /// The Keyboard Shortcuts editor (R59): cmux-page://cmux.keybindings/.
    static let keybindings = PageDescriptor(
        id: "cmux.keybindings", resource: "keybindings", processGroup: .privileged, namespaces: ["cmux.keybindings."], ownsSearchField: true,
        // KeybindingsPageProvider. Export and import go through the native file panel.
        opTables: [PageOpTable(namespace: "cmux.keybindings.", read: ["list", "recorded", "changed"],
                               act: ["record.start", "record.stop", "keymap.export", "keymap.import", "set", "remove", "reset"])])
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
        guard let page = services.webUI.open(PageOpenRequest(descriptor: .keybindings, routes: routes,
                                                             route: restoredRoutes.removeValue(forKey: key)))
        else { return NSView() }
        provider.pageWindow = { [weak page] in page?.window }
        tabs[key] = (page, provider)
        return page
    }

    /// The page and its ops of each tab, by key.
    private var tabs: [String: (page: PageWebView, provider: KeybindingsPageProvider)] = [:]
    /// The route a tab whose view was released opens on again.
    private var restoredRoutes: [String: String] = [:]

    func tabClosed(_ key: String) {
        restoredRoutes.removeValue(forKey: key)
        guard let tab = tabs.removeValue(forKey: key) else { return }
        services.webUI.close(tab.page)
    }

    // MARK: Discard (memory.discard.internalPages)

    /// Every change is written as it is made; a shortcut being recorded is the page's only edit
    /// not yet written (Chrome's kUserEdits), which a rebuilt page cannot show again.
    var discardPolicy: InternalPageDiscardPolicy { .standard }

    func keepReasons(for key: String) -> Set<CannotDiscardReason> {
        tabs[key]?.provider.isRecording == true ? [.unsavedEdits] : []
    }

    func saveViewState(for key: String) -> InternalPageViewState? {
        tabs[key].map { InternalPageViewState(route: $0.page.route) }
    }

    func restoreViewState(_ state: InternalPageViewState, for key: String) {
        restoredRoutes[key] = state.route
    }

    /// The tab stays: its page closes and its saved route is kept for the next view.
    func viewDiscarded(_ key: String) {
        guard let tab = tabs.removeValue(forKey: key) else { return }
        services.webUI.close(tab.page)
    }
}
