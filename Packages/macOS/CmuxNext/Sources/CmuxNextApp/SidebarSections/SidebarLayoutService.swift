import CmuxNextActions
import CmuxNextDesign
import CmuxNextSidebar
import Foundation
import Observation
import os

/// The user's sidebar section layout as this app shows it
/// (plans/cmux-next/sidebar-sections.md 5). The workspace store owns the
/// document (`sidebar-layout-v1`). The service keeps the confirmed mirror,
/// written only by the owner's replies and fetches, and one ordered log of
/// pending intents; the visible `document` is the mirror with the pending
/// intents applied by the same reducer (OWNERSHIP-PRINCIPLES "clients are
/// projections"). An intent leaves the log on its reply or reject; a
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
    /// The owner's confirmed layout.
    @ObservationIgnored private(set) var mirror: SidebarLayoutDocument = .defaults
    /// Ops sent (or to resend) in order, each with its idempotency key.
    @ObservationIgnored private(set) var pending: [(key: String, op: SidebarLayoutOp, inFlight: Bool)] = []
    @ObservationIgnored private var prototype = SidebarLayoutMemoryOwner()
    @ObservationIgnored private let prototypeEnabled: @MainActor () -> Bool
    @ObservationIgnored let remote: (any SidebarLayoutRemote)?
    @ObservationIgnored private let onRefused: @MainActor (String) -> Void
    @ObservationIgnored private var observation: Task<Void, Never>?
    @ObservationIgnored private var legacyObservation: Task<Void, Never>?
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

    init(remote: (any SidebarLayoutRemote)? = nil, onRefused: @escaping @MainActor (String) -> Void = { _ in },
         prototypeEnabled: @escaping @MainActor () -> Bool = {
             DevTools.isEnabled && SidebarSectionTunables.localPrototype.override == true
         }, recentsOffered: UserDefaults = .standard) {
        self.remote = remote
        self.onRefused = onRefused
        self.prototypeEnabled = prototypeEnabled
        self.recentsOffered = recentsOffered
    }

    isolated deinit {
        observation?.cancel()
        legacyObservation?.cancel()
    }

    /// Follows the owner: fetch when it becomes reachable and after each
    /// personal change, and resend intents a disconnect interrupted.
    func start() {
        guard let remote, observation == nil else { return }
        // task-owner: the service (cancelled in deinit); event-driven (Observation)
        observation = Task { [weak self] in
            for await (available, _) in Observations({ (remote.isAvailable, remote.changeToken) }) {
                guard let self, available else { continue }
                self.refresh()
                self.resendInterrupted()
            }
        }
        // task-owner: the service (cancelled in deinit); event-driven (Observation).
        // A session tree that loads, or a legacy pin that changes, re-runs the one-time pin move.
        legacyObservation = Task { [weak self] in
            for await _ in Observations({ remote.legacyPins }) { self?.migrateIfNeeded() }
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
        pending.append((key, op, true))
        recompute()
        dispatch(key, op)
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
        // task-owner: one sidebar_layout.update; settles its intent
        Task { [weak self] in
            do {
                let confirmed = try await remote.update(op, key: key)
                self?.settle(key, confirmed: confirmed)
            } catch {
                guard let self else { return }
                if isDisconnect(error) {
                    self.markInterrupted(key)
                } else {
                    self.settle(key, confirmed: nil)
                    Self.logger.info("sidebar layout: refused \(String(describing: op), privacy: .public): \(String(describing: error), privacy: .public)")
                    self.onRefused(RefusalStrings.describe(error))
                }
            }
        }
    }

    /// The intent's reply (or reject, with nil) arrived.
    func settle(_ key: String, confirmed: SidebarLayoutDocument?) {
        pending.removeAll { $0.key == key }
        if let confirmed { adopt(confirmed) }
        recompute()
    }

    private func markInterrupted(_ key: String) {
        guard let index = pending.firstIndex(where: { $0.key == key }) else { return }
        pending[index].inFlight = false
    }

    private func resendInterrupted() {
        for index in pending.indices where !pending[index].inFlight {
            pending[index].inFlight = true
            dispatch(pending[index].key, pending[index].op)
        }
    }

    /// Fetches the owner's layout.
    func refresh() {
        guard let remote else { return }
        // task-owner: one sidebar_layout.get
        Task { [weak self] in
            guard let confirmed = try? await remote.get() else { return }
            self?.fetched = true
            self?.adopt(confirmed)
            self?.recompute()
            self?.migrateIfNeeded()
        }
    }

    /// A stored layout that still equals the window rail's default (Leo,
    /// 2026-10-03, removed by R52) moves back to the sections default
    /// (`SidebarLayoutDocument.sectionsMigrationOps`) through
    /// ordinary intents, so the owner applies and syncs it like any edit. A
    /// layout the user changed is never touched. Waits for a quiet log, so
    /// it reads the owner's layout rather than one with the user's edits in
    /// flight.
    func migrateIfNeeded() {
        guard fetched, usesOwner, pending.isEmpty else { return }
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
        var visible = mirror
        for entry in pending {
            if case .success(let next) = SidebarLayoutReducer.reduce(visible, entry.op) { visible = next }
        }
        if visible != document { document = visible }
    }
}
