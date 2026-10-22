import CmuxNextDaemon
import CmuxNextWakeups

/// A tab a pane makes only to send it to the side (Leo 2026-10-21: "the OPENING TAB ANIMATION
/// starts on the LEFT then continues on the RIGHT"). A link, file or agent tab opened to the right is
/// made unselected in the pane it was opened from, then moved into a new split or column
/// (``LinkOpener``, ``AgentBesidePlacement``), or the lone chat it shares that pane with docks left
/// (``MainPaneLayout/dockChat(of:keeping:focus:services:outbound:then:)``). The source strip listed it
/// for that round trip, so the tab showed up on the left before its pane came in on the right. Its
/// pane's strip leaves it out until it has left (or the chat has), so it first shows where it lands.
/// The daemon's echo can list the tab before its answer names it: until then every tab the pane did
/// not have when the open began is left out, for at most ``answerLimit``, but the one the pane shows or
/// waits to select (a person's Cmd-T meanwhile). The open's own stand-in (a page tab's, which shows
/// until the daemon's tab replaces it) stays out as long as it is listed.
@MainActor
final class OutboundTab {
    /// How long an open that has not named its tab holds back the pane's new tabs.
    static let answerLimit: Duration = .seconds(2)
    /// How long a landed move keeps the tab out of the source strip for the store to agree.
    static let landLimit: Duration = .seconds(2)
    /// How long a named tab (or an open never named) stays out without its move finishing: past every
    /// wait of the opens (30 s), so a hung move never hides a tab for good.
    static let backstop: Duration = .seconds(60)

    /// By pane controller: a static of the open, not a pane property (the godfile limit counts
    /// PaneController's extensions), as `NewTabSuccession` keeps its opens.
    private static var open: [ObjectIdentifier: [OutboundTab]] = [:]

    private weak var pane: PaneController?
    private let key: ObjectIdentifier
    /// The pane's tabs when the open began.
    private let known: Set<String>
    /// The tab's surface, once the open names it.
    private(set) var surface: SurfaceID?
    /// Or its ids: an agent tab's stand-in, then the store's tab that replaces it (``rekeyed(_:to:)``).
    private var names: Set<String> = []
    /// The open's own stand-ins (provisional tabs it made here, unselected).
    private var own: Set<String> = []
    /// Left out only while the pane still holds this tab (the chat docking away from the tab).
    private var holding: String?
    private var answering = true
    private let timer = DemandTimer(owner: "OutboundTab")

    private init(pane: PaneController) {
        self.pane = pane
        key = ObjectIdentifier(pane)
        known = Set(pane.pane.tabs.map(\.id))
        timer.schedule(after: Self.answerLimit) { @MainActor [weak self] in
            // Not named yet (slow, refused or failed): the pane's new tabs show; a late answer still hides its own.
            guard let self, self.answering else { return }
            self.answering = false
            self.pane?.syncStripFromStore()
            self.timer.schedule(after: Self.backstop) { @MainActor [weak self] in self?.end() }
        }
    }

    /// Whether `tab` of `pane`'s tabs stays out of its strip now.
    func hides(_ tab: TabModel, among tabs: [TabModel]) -> Bool {
        if let holding, !tabs.contains(where: { $0.id == holding }) { return false }
        if own.contains(tab.id) { return true }
        if surface != nil || !names.isEmpty { return tab.surface == surface || names.contains(tab.id) }
        return answering && !known.contains(tab.id) && !shownByPane(tab)
    }

    /// The tab `pane` shows or waits to select: never the open's (made unselected).
    private func shownByPane(_ tab: TabModel) -> Bool {
        guard let pane else { return false }
        return tab.surface == pane.pendingSelectSurface || tab.id == pane.pendingSelectTab || tab.id == pane.stripModel.selectedID?.rawValue
    }

    /// Keeps the open's stand-ins listed now (provisional, new and not the pane's) out until they go.
    private func latchStandIns() {
        guard let pane else { return }
        own.formUnion(pane.pane.tabs.filter { !known.contains($0.id) && ProvisionalTab.isProvisional($0.id) && !shownByPane($0) }.map(\.id))
    }

    /// `opened`, what the open returned, passed on (its stand-in, made now, stays out); an open refused at
    /// once leaves the pane's tabs alone.
    func started(_ opened: Bool) -> Bool {
        if opened { latchStandIns() } else { finish(moved: false) }
        return opened
    }

    /// The open named its tab: only that one stays out.
    func made(_ surface: SurfaceID) {
        self.surface = surface
        didName()
    }

    /// Same, by tab id: an agent tab's stand-in, then the store's tab that replaces it.
    func made(key: String) {
        names.insert(key)
        if let real = pane?.services.agentTabs.aliases[key] { names.insert(real) }
        didName()
    }

    /// The store made provisional tab `key` as `real` (``AgentTabStore/rekey(_:to:)``): an open that
    /// holds `key` holds `real` too, before the pane lists it.
    static func rekeyed(_ key: String, to real: String) {
        for tab in open.values.joined() where tab.names.contains(key) { tab.names.insert(real) }
    }

    private func didName() {
        latchStandIns()
        answering = false
        timer.schedule(after: Self.backstop) { @MainActor [weak self] in self?.end() }
        pane?.syncStripFromStore()
    }

    /// The tab stays in this pane and shows once tab `id` (the chat) has left it.
    func hidden(whileHolding id: String) {
        holding = id
    }

    /// The move is over. Landed: the tab stays out until the store has it elsewhere (bounded by
    /// ``landLimit``). Failed or never made: the strip lists it now, so it never stays hidden.
    func finish(moved: Bool) {
        answering = false
        guard moved else { return end() }
        timer.schedule(after: Self.landLimit) { @MainActor [weak self] in self?.end() }
    }

    private func end() {
        timer.cancel()
        Self.open[key]?.removeAll { $0 === self }
        if Self.open[key]?.isEmpty == true { Self.open[key] = nil }
        pane?.syncStripFromStore()
    }

    /// Starts leaving out of `pane`'s strip the tab about to be made there for a move to the side.
    static func begin(in pane: PaneController) -> OutboundTab {
        let tab = OutboundTab(pane: pane)
        open[tab.key, default: []].append(tab)
        return tab
    }

    /// The ids of `pane`'s tabs that are on their way out.
    static func hidden(in pane: PaneController) -> Set<String> {
        guard let opens = open[ObjectIdentifier(pane)]?.filter({ $0.pane === pane }), !opens.isEmpty else { return [] }
        let tabs = pane.pane.tabs
        return Set(tabs.filter { tab in opens.contains { $0.hides(tab, among: tabs) } }.map(\.id))
    }
}
