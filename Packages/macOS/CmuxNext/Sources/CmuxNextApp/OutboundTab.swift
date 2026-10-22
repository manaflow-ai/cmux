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
/// not have when the open began is left out, for at most ``answerLimit``.
@MainActor
final class OutboundTab {
    /// How long an open that has not named its tab holds back the pane's new tabs.
    static let answerLimit: Duration = .seconds(2)
    /// How long a landed move keeps the tab out of the source strip for the store to agree.
    static let landLimit: Duration = .seconds(2)

    /// By pane controller: a static of the open, not a pane property (the godfile limit counts
    /// PaneController's extensions), as `NewTabSuccession` keeps its opens.
    private static var open: [ObjectIdentifier: [OutboundTab]] = [:]

    private weak var pane: PaneController?
    private let key: ObjectIdentifier
    /// The pane's tabs when the open began.
    private let known: Set<String>
    /// The tab's surface, once the open names it.
    private(set) var surface: SurfaceID?
    /// Left out only while the pane still holds this tab (the chat docking away from the tab).
    private var holding: String?
    private var answering = true
    private let timer = DemandTimer(owner: "OutboundTab")

    private init(pane: PaneController) {
        self.pane = pane
        key = ObjectIdentifier(pane)
        known = Set(pane.pane.tabs.map(\.id))
        timer.schedule(after: Self.answerLimit) { @MainActor [weak self] in
            // An open that never named its tab (refused, or it failed) leaves the pane's tabs alone.
            guard let self, self.answering, self.surface == nil else { return }
            self.end()
        }
    }

    /// Whether `tab` of `pane`'s tabs stays out of its strip now.
    func hides(_ tab: TabModel, among tabs: [TabModel]) -> Bool {
        if let holding, !tabs.contains(where: { $0.id == holding }) { return false }
        if let surface { return tab.surface == surface }
        return answering && !known.contains(tab.id)
    }

    /// `opened`, what the open returned, passed on; an open refused at once leaves the pane's tabs alone.
    func started(_ opened: Bool) -> Bool {
        if !opened { finish(moved: false) }
        return opened
    }

    /// The open named its tab: only that one stays out.
    func made(_ surface: SurfaceID) {
        self.surface = surface
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
