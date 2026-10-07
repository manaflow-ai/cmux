import AppKit
import CmuxHomeCore
import CmuxNextActions
import CmuxNextDesign
import CmuxNextHome
import Observation

/// The Home top page, two columns: MessagesLab's conversation list
/// (`HomeSidebarView` over `HomeSidebarSource`: search, the pinned grid with
/// the Chiefs, then conversations newest first) on the left, and the chosen conversation's native transcript
/// (`HomeHostView`, MessagesLab's code) on the right. The page opens on the
/// Chief conversation when there is one, else on the newest conversation.
/// The store's home workspace and its chief tab stay as they are (other
/// clients read them); this page reads the same store.
@MainActor
final class TopHomePageView: NSView {
    private weak var services: AppServices?
    let list = HomeSidebarView()
    /// The sidebar's data (pins, search, the Messages-style model).
    let sidebar: HomeSidebarSource
    let transcriptColumn = NSView()
    let split: HomeSidebarSplitView
    /// The rows shown (archived Chiefs hidden), for `debug.home page`.
    private(set) var rows: [InboxRow] = []
    var lines: [HomeConversationLine] { rows.homeLines }
    private(set) var host: HomeHostView?
    private(set) var shown: ConversationID?
    private var rowsObservation: Task<Void, Never>?
    private var selectionObservation: Task<Void, Never>?
    private var chiefObservation: Task<Void, Never>?
    private var accountObservation: Task<Void, Never>?

    init(services: AppServices, windowKey: @escaping () -> String) {
        self.services = services
        sidebar = services.home.makeSidebarSource()
        split = HomeSidebarSplitView(sidebar: list, content: transcriptColumn)
        super.init(frame: .zero)
        setAccessibilityIdentifier("cmux.topPage.home")
        split.windowKey = windowKey
        split.frame = bounds
        split.autoresizingMask = [.width, .height]
        addSubview(split)
        wireList(services)
        observe(services.home)
        // task-owner: lives as long as this view; one read of the team and Chiefs
        Task { await services.home.directory.refresh() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    isolated deinit {
        rowsObservation?.cancel()
        selectionObservation?.cancel()
        chiefObservation?.cancel()
        accountObservation?.cancel()
    }

    private func wireList(_ services: AppServices) {
        let sidebar = sidebar
        list.onSelect = { [weak self] id in self?.show(id) }
        list.onSetPinned = { on, id in sidebar.setPinned(on, id) }
        let home = services.home
        let registry = services.registry
        // Mark as Read: the read cursor moves to the newest message.
        list.onMarkRead = { id in
            guard let row = home.homeStore.rows.first(where: { $0.id == id }) else { return }
            let store = home.homeStore
            // task-owner: one op; ends with the owner's answer
            Task { _ = try? await store.perform(.setReadCursor(conversation: id, seq: row.summary.lastSeq)) }
        }
        // Archive Chief on a Chief's row (the same action as the palette and the CLI).
        list.menuItems = { id in
            guard let row = home.homeStore.rows.first(where: { $0.id == id }), row.kind == .chief,
                  let chief = row.summary.participants.lazy.compactMap({ home.directory.chief(for: $0.id) }).first,
                  let title = registry.title(for: "home.archiveChief") else { return [] }
            return [HomeSidebarView.menuItem(title) {
                _ = registry.perform("home.archiveChief", invocation: ActionInvocation(arguments: ["chief": .string(chief.id)], origin: .user))
            }]
        }
        // Search: teammates with no DM yet, under the conversations; choosing one starts the DM.
        list.teammates = { [weak sidebar] query in
            guard let sidebar else { return [] }
            return HomeSidebarModel(rows: home.homeStore.rows, pins: sidebar.pins, me: home.homeStore.me?.id, query: query,
                                    contacts: home.contacts()).people
        }
        list.onStartTeammate = { person in
            // task-owner: one conversation start; ends with the owner's answer
            Task { _ = await home.startConversation([.contact(person)], title: "") }
        }
        list.onNewMessage = { [weak self] in self?.presentNewMessage() }
        list.composeMenu = { [weak services] in services.map { HomePageMenus.backgroundMenu(registry: $0.registry) } }
    }

    /// Follows the inbox rows (Observation) and the conversation an action
    /// asked to show once it is listed.
    private func observe(_ home: HomeService) {
        let store = home.homeStore
        // task-owner: lives as long as this view; event-driven (Observation)
        let sidebar = sidebar
        rowsObservation = Task { [weak self] in
            for await (all, archived, _, _) in Observations({ (store.rows, home.directory.archivedChiefs, sidebar.query, sidebar.pins) }) {
                guard let self else { return }
                rows = Self.visible(all, archivedChiefs: archived, me: store.me?.id)
                list.update(sidebar.model())
                if shown == nil, let first = defaultConversation(rows: rows, home: home) { show(first) }
            }
        }
        // task-owner: lives as long as this view; event-driven (Observation). The chief placed
        // on a paired server (G6) replaces the local chief while the page shows the local one.
        chiefObservation = Task { [weak self] in
            var previous = Self.chief(home)
            for await chief in Observations({ Self.chief(home) }) {
                guard let self, let chief, chief != previous else { continue }
                if shown == nil || shown?.rawValue == previous { show(ConversationID(chief)) }
                previous = chief
            }
        }
        let auth = home.services.cloud.auth
        // task-owner: lives as long as this view; event-driven (Observation). Another account has its own pins.
        accountObservation = Task {
            for await _ in Observations({ auth.user?.id }) { sidebar.reloadPins() }
        }
        // task-owner: lives as long as this view; event-driven (Observation)
        selectionObservation = Task { [weak self] in
            for await pending in Observations({ (home.pendingSelection, store.rows.map(\.id)) }) {
                guard let self, let id = pending.0, pending.1.contains(id) else { continue }
                home.pendingSelection = nil
                show(id)
            }
        }
    }

    /// The rows the list shows: an archived Chief's conversation is hidden
    /// (its history stays with the owner, read-only).
    static func visible(_ rows: [InboxRow], archivedChiefs: Set<String>, me: ParticipantID?) -> [InboxRow] {
        guard !archivedChiefs.isEmpty else { return rows }
        return rows.filter { row in
            guard row.kind == .chief else { return true }
            return !row.summary.participants.contains { $0.id != me && archivedChiefs.contains($0.id.rawValue) }
        }
    }

    /// The Chief's conversation (the chief placed on a server takes over a
    /// local one without history: `HomeChiefSource`), else the first listed conversation.
    private func defaultConversation(rows: [InboxRow], home: HomeService) -> ConversationID? {
        if let chief = Self.chief(home) { return ConversationID(chief) }
        return rows.homeLines.lazy.compactMap(\.conversation).first
    }

    static func chief(_ home: HomeService) -> String? {
        let local = HomeChiefName.select(from: home.conversations)
        return HomeChiefSource.choose(local: local?.id, localHasHistory: (local?.lastSeq ?? 0) > 0, placed: home.cloudChief)
    }

    /// Shows `id` in the transcript column and selects it in the list.
    func show(_ id: ConversationID) {
        list.select(id)
        guard id != shown, let services else { return }
        shown = id
        host?.removeFromSuperview()
        let view = HomeHostView(services: services, conversation: id.rawValue)
        view.frame = transcriptColumn.bounds
        view.autoresizingMask = [.width, .height]
        transcriptColumn.addSubview(view)
        host = view
        services.home.homeDidOpen()
        if window?.firstResponder === window || window?.firstResponder == nil { focusPrimaryInput() }
    }

    /// Home's primary input (the message box) takes the keyboard.
    func focusPrimaryInput() {
        guard let target = host?.focusTarget else { return }
        window?.makeFirstResponder(target)
    }

    // MARK: Sheets

    func presentNewMessage() {
        guard let services else { return }
        let home = services.home
        let sheet = HomeComposeSheet(contacts: home.contacts())
        sheet.onStart = { recipients, title in await home.startConversation(recipients, title: title) }
        sheet.onInviteInstead = { [weak self] prefill in self?.presentInvite(prefill: prefill) }
        present(sheet)
        // The team may arrive after the sheet opened: a refreshed list waits for the next sheet.
        Task { await home.directory.refresh() }
    }

    func presentInvite(prefill: String) {
        guard let services else { return }
        let home = services.home
        let pending = home.homeStore.rows.pendingInvites.map(\.contact)
        let sheet = HomeInviteSheet(prefill: prefill, pending: pending)
        sheet.onSend = { address in await home.invite(address) }
        present(sheet)
    }

    func presentNewChief() {
        guard let services else { return }
        let home = services.home
        let sheet = HomeNewChiefSheet()
        sheet.onCreate = { name in await home.createChief(named: name) }
        present(sheet)
    }

    private func present(_ sheet: HomeSheetController) {
        sheet.onFinish = { [weak self] id in
            guard let self, let id else { return }
            // Shown now when listed; else once the inbox lists it.
            if services?.home.homeStore.rows.contains(where: { $0.id == id }) == true { show(id) } else { services?.home.pendingSelection = id }
        }
        guard let window else { return }
        let panel = NSWindow(contentViewController: sheet)
        window.beginSheet(panel)
    }
}
