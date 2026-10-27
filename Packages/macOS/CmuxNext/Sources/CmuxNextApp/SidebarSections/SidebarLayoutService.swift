import CmuxNextActions
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextSidebar
import CmuxNextWakeups
import Foundation
import Observation
import os

/// The user's sidebar section layout as this app shows it
/// (plans/cmux-next/sidebar-sections.md 5). The workspace store owns the
/// document (`sidebar-layout-v1`). The service keeps the confirmed mirror,
/// written only by the owner's replies and fetches, and one ordered log of
/// pending intents; the visible `document` is the mirror with the pending
/// intents applied by the same reducer (OWNERSHIP-PRINCIPLES "clients are
/// projections"). Intents go to the owner one at a time in log order (an
/// op can depend on the one before it: a section add, then an item add into
/// it; Add Home, then its undo), so the owner applies them in the order the
/// person made them. An intent leaves the log on its reply or reject; a
/// disconnect keeps it, and it is resent with its key on reconnect. While
/// the owner is unreachable, edits are refused (nothing queues), except in
/// DEV with Debug Settings `sidebar.sections.localPrototype`, which edits an
/// in-memory copy that is never saved. A stored layout that still equals
/// the pre-rail default migrates to the rail default once per session, and
/// one equal to a default from before Recents gains it once per Mac.
@Observable @MainActor
final class SidebarLayoutService {
    /// The capability the store serves the layout under.
    static let capability = "sidebar-layout-v1"

    private(set) var document: SidebarLayoutDocument = .defaults
    /// The sidebar document's bands (`sidebar-doc-v1`, SidebarDocWiring):
    /// when set, the base the pending intents apply over, and no migration runs.
    @ObservationIgnored var docLayout: SidebarLayoutDocument? { didSet { recompute() } }
    /// The owner's confirmed layout.
    @ObservationIgnored private(set) var mirror: SidebarLayoutDocument = .defaults
    /// Ops to send in order, each with its idempotency key; at most the first is in flight.
    @ObservationIgnored private(set) var pending: [(key: String, op: SidebarLayoutOp, inFlight: Bool)] = []
    @ObservationIgnored private var prototype = SidebarLayoutMemoryOwner()
    @ObservationIgnored private let prototypeEnabled: @MainActor () -> Bool
    @ObservationIgnored let remote: (any SidebarLayoutRemote)?
    @ObservationIgnored private let onRefused: @MainActor (String) -> Void
    /// The main-thread scheduler the owner's follow flushes on.
    @ObservationIgnored private let mainWork: MainWorkScheduler
    /// Starts each owner call at a stated priority.
    @ObservationIgnored private let work: BackgroundWork
    @ObservationIgnored private var observation: ServiceObservation<OwnerState>?
    @ObservationIgnored private var legacyObservation: ServiceObservation<[LegacyPins]>?
    /// What the follow reads of the owner: whether it is reachable, and its personal state's change token. Not
    /// Equatable on purpose: a reconnect inside one turn reads the same values and must still fetch and resend.
    private struct OwnerState {
        var available: Bool
        var changeToken: UInt64
    }
    /// The owner's layout has been read once (migrations plan against it).
    @ObservationIgnored private var fetched = false
    /// The sections migration went out this session (at most once, so an
    /// owner that refuses it is not asked again on every fetch).
    @ObservationIgnored private var migrationSent = false
    /// Sessions whose legacy pins went out as tiles this run (`migrateLegacyPins`).
    @ObservationIgnored var legacyPinsSent: Set<String> = []
    /// Sessions whose legacy flags were cleared this run (`migrateLegacyPins`).
    @ObservationIgnored var legacyPinsCleared: Set<String> = []
    /// This Mac added Recents to the layout, or saw it there, once.
    @ObservationIgnored private let recentsOffered: UserDefaults
    static let recentsOfferedKey = "cmux.next.sidebar.recentsOffered"
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "sidebar-layout")

    /// - Parameters:
    ///   - remote: The layout's owner (the home daemon), nil for none.
    ///   - mainWork: The app's main-thread scheduler the owner's follow flushes on.
    ///   - work: Starts the owner calls at a stated priority.
    ///   - onRefused: Shows an owner's refusal.
    ///   - prototypeEnabled: DEV's in-memory prototype.
    ///   - recentsOffered: Where this Mac records that it offered Recents.
    init(remote: (any SidebarLayoutRemote)? = nil, mainWork: MainWorkScheduler, work: BackgroundWork,
         onRefused: @escaping @MainActor (String) -> Void = { _ in },
         prototypeEnabled: @escaping @MainActor () -> Bool = {
             DevTools.isEnabled && SidebarSectionTunables.localPrototype.override == true
         }, recentsOffered: UserDefaults = .standard) {
        self.remote = remote
        self.mainWork = mainWork
        self.work = work
        self.onRefused = onRefused
        self.prototypeEnabled = prototypeEnabled
        self.recentsOffered = recentsOffered
    }

    /// Follows the owner: fetch when it becomes reachable and after each
    /// personal change, and resend intents a disconnect interrupted. Service observations: they write the
    /// mirror and send intents whether or not a sidebar shows.
    func start() {
        guard let remote, observation == nil else { return }
        // `visible`: every window's sidebar draws the layout.
        observation = ServiceObservation(.visible, owner: "SidebarLayout.owner", on: mainWork) {
            OwnerState(available: remote.isAvailable, changeToken: remote.changeToken)
        } apply: { [weak self] state in
            guard let self, state.available else { return }
            refresh()
            resendInterrupted()
        }
        // A session tree that loads, or a legacy pin that changes, re-runs the one-time pin move. `background`:
        // a one-time move nobody waits on.
        legacyObservation = ServiceObservation(.background, owner: "SidebarLayout.legacyPins", on: mainWork) {
            remote.legacyPins
        } apply: { [weak self] _ in
            self?.migrateIfNeeded()
        }
    }

    var usesOwner: Bool { remote?.isAvailable ?? false }

    /// Why edits are refused now, or nil when they apply.
    var unavailableReason: String? {
        usesOwner || prototypeEnabled() ? nil : RefusalStrings.needsDaemonCapability(Self.capability)
    }

    /// Applies `op`: to the owner as an intent (visible at once, settled by
    /// its reply), or to the DEV prototype. Throws the refusal when edits
    /// are unavailable or the reducer rejects the op against the visible
    /// layout (the owner checks again).
    func send(_ op: SidebarLayoutOp) throws {
        guard usesOwner else { return try sendToPrototype(op) }
        if case .failure(let reject) = SidebarLayoutReducer.reduce(document, op) {
            throw ActionFailure(message: SidebarSectionStrings.rejected(reject.rawValue))
        }
        let key = "sidebar-layout-" + UUID().uuidString.lowercased()
        pending.append((key, op, false))
        recompute()
        sendNext()
    }

    private func sendToPrototype(_ op: SidebarLayoutOp) throws {
        guard prototypeEnabled() else { throw ActionFailure(message: RefusalStrings.needsDaemonCapability(Self.capability)) }
        switch prototype.apply(op, key: UUID().uuidString) {
        case .success(let next):
            if next != document { document = next }
        case .failure(let reject):
            throw ActionFailure(message: SidebarSectionStrings.rejected(reject.rawValue))
        }
    }

    private func dispatch(_ key: String, _ op: SidebarLayoutOp) {
        guard let remote else { return }
        let mainWork = mainWork
        // task-owner: one sidebar_layout.update, awaited off main (recipe R-hop). Its reply settles an edit that
        // already shows: the rest of the person's action, one userBlocking task (p06-scheduler.md rule 2).
        work.task(.userBlocking) { @concurrent [weak self] in
            let reply: Result<SidebarLayoutDocument, any Error>
            do { reply = .success(try await remote.update(op, key: key)) } catch { reply = .failure(error) }
            await mainWork.apply(.userBlocking, owner: "SidebarLayout.settle") { [weak self] in
                guard let self else { return }
                self.settleReply(key, op, reply)
            }
        }
    }

    /// The owner's reply to intent `key`: settled, kept first in the log for the reconnect (a disconnect), or
    /// refused (settled with nothing, and the refusal shown).
    private func settleReply(_ key: String, _ op: SidebarLayoutOp, _ reply: Result<SidebarLayoutDocument, any Error>) {
        switch reply {
        case .success(let confirmed):
            settle(key, confirmed: confirmed)
        case .failure(let error) where isDisconnect(error):
            markInterrupted(key)
        case .failure(let error):
            settle(key, confirmed: nil)
            Self.logger.info("sidebar layout: refused \(String(describing: op), privacy: .public): \(String(describing: error), privacy: .public)")
            onRefused(RefusalStrings.describe(error))
        }
    }

    /// The intent's reply (or reject, with nil) arrived; the next one goes out.
    func settle(_ key: String, confirmed: SidebarLayoutDocument?) {
        pending.removeAll { $0.key == key }
        if let confirmed { adopt(confirmed) }
        recompute()
        sendNext()
    }

    /// Sends the oldest intent when none is in flight (one at a time, in log order).
    private func sendNext() {
        guard remote != nil, !pending.contains(where: \.inFlight), let first = pending.first else { return }
        pending[0].inFlight = true
        dispatch(first.key, first.op)
    }

    /// A disconnect: the intent stays first in the log and waits for the reconnect.
    private func markInterrupted(_ key: String) {
        guard let index = pending.firstIndex(where: { $0.key == key }) else { return }
        pending[index].inFlight = false
    }

    private func resendInterrupted() {
        sendNext()
    }

    /// Fetches the owner's layout.
    func refresh() {
        guard let remote else { return }
        let mainWork = mainWork
        // task-owner: one sidebar_layout.get, awaited off main (recipe R-hop); what it read shows in one visible task.
        work.task(.userVisible) { @concurrent [weak self] in
            guard let confirmed = try? await remote.get() else { return }
            await mainWork.apply(.visible, owner: "SidebarLayout.fetch") { [weak self] in
                guard let self else { return }
                self.adoptFetched(confirmed)
            }
        }
    }

    /// The owner's layout, read: the mirror moves to it and the migrations plan against it.
    private func adoptFetched(_ confirmed: SidebarLayoutDocument) {
        fetched = true
        adopt(confirmed)
        recompute()
        migrateIfNeeded()
    }

    /// A stored layout that still equals the window rail's default (Leo,
    /// 2026-10-03, removed by R52) moves back to the sections default
    /// (`SidebarLayoutDocument.sectionsMigrationOps`) through
    /// ordinary intents, so the owner applies and syncs it like any edit. A
    /// layout the user changed is never touched. Waits for a quiet log, so
    /// it reads the owner's layout rather than one with the user's edits in
    /// flight.
    func migrateIfNeeded() {
        guard fetched, usesOwner, pending.isEmpty, docLayout == nil else { return }
        migrateSections()
        if pending.isEmpty { migrateLegacyPins() }
    }

    private func migrateSections() {
        guard !migrationSent else { return }
        // Recents is added once per Mac: a layout without it after that is one the user removed it from.
        let offered = recentsOffered.bool(forKey: Self.recentsOfferedKey)
        let ops = mirror.layoutMigrationOps(offeringRecents: !offered)
        let addsRecents = ops.contains { op in
            if case .sectionAdd(let section, _) = op { section.id == SidebarLayoutDocument.recentsSectionID } else { false }
        }
        if !offered, addsRecents || mirror.section(SidebarLayoutDocument.recentsSectionID) != nil {
            recentsOffered.set(true, forKey: Self.recentsOfferedKey)
        }
        guard !ops.isEmpty else { return }
        migrationSent = true
        for op in ops {
            do { try send(op) } catch { return }
        }
    }

    /// The mirror only moves forward (a late reply never rolls it back).
    private func adopt(_ confirmed: SidebarLayoutDocument) {
        if confirmed.revision >= mirror.revision { mirror = confirmed }
    }

    /// Visible = mirror + pending intents (a pending op the mirror now
    /// rejects shows nothing until its own reply settles it).
    private func recompute() {
        var visible = docLayout ?? mirror
        for entry in pending {
            if case .success(let next) = SidebarLayoutReducer.reduce(visible, entry.op) { visible = next }
        }
        if visible != document { document = visible }
    }
}
