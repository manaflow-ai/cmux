import AppKit
import CmuxHomeCore
import CmuxNextActions
import CmuxNextHome

extension InternalPageID {
    static let newChief = InternalPageID(rawValue: "new-chief")
}

/// New Chief… as a page tab (Leo 2026-10-21, "Chief: sheet as workspace"): the New Chief card
/// (``HomeNewChiefSheet`` in a ``HomeSheetPageView``) in a tab beside your work, or beside the
/// Chief on Home when another column shows there (`pageTabPane`), instead of a sheet over Home.
/// Home's Chief dock alone keeps the sheet (`holdsTab(in:)`). Create makes the Chief through
/// Home's one create path (`HomeService.createChief`), closes the tab and shows the new Chief's
/// conversation in Home; Cancel closes the tab. One tab per window: New Chief… again selects it.
/// `HomeTunables.newChiefSheet` brings the sheet back for one release.
@MainActor
final class NewChiefPage: InternalPageProvider {
    /// What the page reaches in the app.
    struct Host {
        var create: @MainActor (String, ChiefBackend) async -> HomeComposeOutcome
        /// Closes the page tab that shows provider key `key`.
        var close: @MainActor (_ key: String) -> Void
        /// Shows Home's conversation `id`.
        var show: @MainActor (_ id: ConversationID) -> Void
    }

    private let host: Host
    /// Tabs still open: a create that finishes after its tab closed (Cmd-W while it ran) closes nothing.
    private var open: Set<String> = []

    init(host: Host) {
        self.host = host
    }

    var page: InternalPageID { .newChief }
    var title: String { HomeSheetPageView.newChiefTitle }
    var symbol: String { "sparkles" }

    func makeView(for key: String, in window: WindowController?) -> NSView {
        let sheet = HomeNewChiefSheet()
        let create = host.create
        sheet.onCreate = { name, backend in await create(name, backend) }
        sheet.onFinish = { [weak self] id in self?.finished(key, showing: id) }
        open.insert(key)
        return HomeSheetPageView(sheet: sheet)
    }

    func tabClosed(_ key: String) {
        open.remove(key)
    }

    private func finished(_ key: String, showing id: ConversationID?) {
        if open.remove(key) != nil { host.close(key) }
        if let id { host.show(id) }
    }
}

extension NewChiefPage {
    /// Registers the page with the app's create, tab close and Home.
    static func register(_ services: AppServices) {
        services.pages.register(NewChiefPage(host: Host(
            create: { [weak services] name, backend in
                await services?.home.createChief(named: name, backend: backend) ?? .offline
            },
            close: { [weak services] key in
                // The pane's own close, as Debug Settings closes its tabs: it takes app-only and store tabs alike.
                guard let services, let pane = services.paneController(showingTab: key),
                      let id = services.pages.stripID(showing: key, in: pane) else { return }
                pane.close([id])
            },
            show: { [weak services] id in
                guard let services else { return }
                // Listed: open it. Not yet: Home shows it once the inbox lists it (`createChief` set `pendingSelection`).
                guard services.home.homeStore.rows.contains(where: { $0.id == id }) else {
                    _ = services.registry.perform("home.show", invocation: ActionInvocation(origin: .user))
                    return
                }
                _ = services.registry.perform("home.openConversation",
                                              invocation: ActionInvocation(arguments: ["conversation": .string(id.rawValue)], origin: .user))
            })))
    }

    /// New Chief… with no name: the page tab in the active window (selected when one shows already).
    /// False when no window can hold it.
    static func open(_ services: AppServices, focus: Bool) -> Bool {
        services.pages.show(.newChief, in: services.windows.active, focus: focus) != nil
    }

    /// Whether New Chief… with no name opens the page tab: wherever it would show the sheet (the
    /// docked Home with Channels off) and the active window can show a tab (`holdsTab(in:)`),
    /// unless the Debug toggle keeps the sheet. Classic Home keeps its sheet (its one top page would
    /// leave Home for a tab nobody sees), Channels its own page route, and a window with no pane to
    /// hold the tab (or no window) the sheet, since a top page's card could not close after Create.
    static func opensAsPage(sheetToggle: Bool, classic: Bool, channels: Bool, holdsTab: Bool) -> Bool {
        !sheetToggle && !classic && !channels && holdsTab
    }

    /// Whether `window` shows the New Chief tab: it shows a workspace pane (`holdsVisiblePageTab`)
    /// whose page-tab pane takes it. Home's Chief dock alone takes no tab, so there the sheet stays.
    static func holdsTab(in window: WindowController?) -> Bool {
        guard let window, window.holdsVisiblePageTab else { return false }
        return window.workspaceContent?.pageTabPaneTakesTabs == true
    }
}

/// The New Chief tab's keyboard lands in its name field when the tab gets it (`FocusEffectApplier`),
/// so typing starts there with no click; inside the card the field or button the person chose keeps it.
extension HomeSheetPageView: PrimaryInputTarget {
    var primaryInputView: NSView? { firstField }

    func primaryInputShouldTakeKeyboard(from responder: NSResponder?) -> Bool {
        guard let view = responder as? NSView else { return true }
        return !view.isDescendant(of: self)
    }
}
