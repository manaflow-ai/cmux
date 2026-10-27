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
    private let services: AppServices

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
        guard let page = services.webUI.open(PageOpenRequest(descriptor: .keybindings, routes: routes)) else { return NSView() }
        provider.pageWindow = { [weak page] in page?.window }
        tabs[key] = (page, provider)
        return page
    }

    /// The page and its ops of each tab, by key.
    private var tabs: [String: (page: PageWebView, provider: KeybindingsPageProvider)] = [:]

    func tabClosed(_ key: String) {
        guard let tab = tabs.removeValue(forKey: key) else { return }
        services.webUI.close(tab.page)
    }

    // MARK: Discard (`memoryDiscardInternalPages`)

    /// Ten minutes hidden: every change is written as it is made.
    func discardPolicy(for key: String) -> ContentDiscardPolicy { .standard }

    /// Kept while the page records a shortcut: the keys it takes are an edit not written yet, which
    /// a rebuilt page cannot show again (Chrome's kUserEdits).
    func keepReasons(for key: String) -> [CannotDiscardReason] {
        tabs[key]?.provider.isRecording == true ? [.unsavedEdits] : []
    }

    func saveViewState(for key: String, content: NSView) async -> ContentViewState {
        await (content as? PageWebView)?.discardViewState() ?? ContentViewState()
    }

    func restoreViewState(_ state: ContentViewState, for key: String, content: NSView) async {
        (content as? PageWebView)?.restoreDiscardViewState(state)
    }

    /// The tab's page went (the tab store closed it); the next view makes its own.
    func viewDiscarded(_ key: String) {
        guard let tab = tabs.removeValue(forKey: key) else { return }
        services.webUI.close(tab.page)
    }
}
