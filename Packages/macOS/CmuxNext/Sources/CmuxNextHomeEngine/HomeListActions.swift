public import AppKit
public import CmuxHomeCore
public import CmuxNextActions
import CmuxNextDesign

/// The Home page a list action reads and redraws (the App's native Home page).
@MainActor
public protocol HomeListPage: AnyObject {
    /// The conversation the page shows.
    var shown: ConversationID? { get }
    /// The page's list source (its pins and hidden conversations).
    var sidebar: HomeSidebarSource { get }
    /// Redraws the list after a pin or hide change.
    func listPinsChanged()
    /// The page left `id` while it showed: `next` shows.
    func conversationLeft(_ id: ConversationID, next: ConversationID?)
}

/// The Home list's own actions: Pin/Unpin a conversation, Delete Conversation from List (hide it
/// until a newer message) and Show Hidden Conversations. One path for the row menus, the palette,
/// the CLI and MCP. The App passes the shown page, the pin source and the named conversation.
@MainActor
public struct HomeListActions {
    private let page: @MainActor () -> (any HomeListPage)?
    private let source: @MainActor () -> HomeSidebarSource
    private let conversation: @MainActor (ActionInvocation) -> ConversationID?
    private let notReady: String
    private let pinTitles: (pin: String, unpin: String)

    /// - Parameters:
    ///   - page: The Home page shown now, if any.
    ///   - source: Where a pin or hide change goes (the shown page's list, else a source over the same stores).
    ///   - conversation: The conversation an invocation names, else the shown one; nil after it refused.
    ///   - notReady: The refusal when Home cannot take the change.
    ///   - pinTitles: The menu titles of Pin and Unpin.
    public init(page: @escaping @MainActor () -> (any HomeListPage)?, source: @escaping @MainActor () -> HomeSidebarSource,
                conversation: @escaping @MainActor (ActionInvocation) -> ConversationID?, notReady: String,
                pinTitles: (pin: String, unpin: String)) {
        (self.page, self.source, self.conversation, self.notReady, self.pinTitles) = (page, source, conversation, notReady, pinTitles)
    }

    public func bind(into registry: ActionRegistry) {
        let (page, source, conversation, notReady, pinTitles) = (page, source, conversation, notReady, pinTitles)
        // One pin path for a Home conversation: the row's Pin/Unpin and grid drags call it too.
        registry.bind("home.togglePin", invoke: { invocation in
            guard let id = conversation(invocation) else { return }
            let pins = source()
            let pinned = invocation["pinned"]?.boolValue ?? !pins.isPinned(id)
            pins.setPinned(pinned, id)
            page()?.listPinsChanged()
        })
        ActionTargetTitles.set("home.togglePin", in: registry) { invocation in
            let text = invocation["conversation"]?.stringValue?.trimmingCharacters(in: .whitespaces)
            guard let id = text.flatMap({ $0.isEmpty ? nil : ConversationID($0) }) ?? page()?.shown else { return nil }
            return source().isPinned(id) ? pinTitles.unpin : pinTitles.pin
        }
        ActionTargetTitles.setPaletteState("home.togglePin", in: registry) {
            guard let id = page()?.shown else { return false }
            return source().isPinned(id)
        }
        // Delete Conversation from List: off this account's Home list until a newer message (the
        // row's Delete Conversation… asks first, then runs this). The page showing it moves to its neighbor.
        registry.bindEffect("home.hideConversation", effect: { invocation in
            guard let id = conversation(invocation) else { return .done }
            let shownPage = page()
            let next = shownPage.flatMap { $0.shown == id ? $0.sidebar.model().neighbor(of: id, offset: 1) : nil }
            guard source().hide(id) else { return .refused(notReady) }
            shownPage?.listPinsChanged()
            if let shownPage, shownPage.shown == id { shownPage.conversationLeft(id, next: next) }
            return .done
        })
        registry.bindEffect("home.showHiddenConversations", effect: { _ in
            source().unhideAll()
            page()?.listPinsChanged()
            return .done
        })
    }

    /// Delete Conversation…'s question (as Messages asks, the cmux dialog so the debug socket can answer it);
    /// `delete` runs on Delete.
    public static func confirmDelete(in window: NSWindow?, _ delete: @escaping @MainActor () -> Void) {
        let spec = CmuxDialogSpec(title: HomeListStrings.deleteConversationTitle, lines: [HomeListStrings.deleteConversationMessage],
                                  buttons: [.cancel(), CmuxDialogButton(id: "delete", title: HomeListStrings.deleteConversationConfirm, role: .destructive)],
                                  identifier: "cmux.dialog.home.deleteConversation")
        CmuxDialogCenter.shared.present(spec, in: window.map(CmuxDialogScope.window) ?? .app) { answer in
            guard answer.button == "delete" else { return }
            delete()
        }
    }
}

/// Delete Conversation…'s question (Resources/Home.xcstrings).
nonisolated enum HomeListStrings {
    static var deleteConversationTitle: String { String(localized: "handlers.misc.home.deleteConversationTitle", defaultValue: "Are you sure you want to delete this conversation?", table: "Home", bundle: .module) }
    static var deleteConversationMessage: String { String(localized: "handlers.misc.home.deleteConversationMessage", defaultValue: "It leaves your Home list. A new message brings it back, and Show Hidden Conversations lists it again.", table: "Home", bundle: .module) }
    static var deleteConversationConfirm: String { String(localized: "handlers.misc.home.deleteConversationConfirm", defaultValue: "Delete", table: "Home", bundle: .module) }
}
