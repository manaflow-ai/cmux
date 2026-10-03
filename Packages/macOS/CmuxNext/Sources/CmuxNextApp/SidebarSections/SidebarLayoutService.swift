import CmuxNextActions
import CmuxNextDesign
import CmuxNextSidebar
import Foundation
import Observation

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
/// the pre-rail default migrates to the rail default once per session.
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
    /// The window rail shows the top sections (`window.rail` is not off).
    @ObservationIgnored private let railShown: @MainActor () -> Bool
    @ObservationIgnored private let remote: (any SidebarLayoutRemote)?
    @ObservationIgnored private let onRefused: @MainActor (String) -> Void
    @ObservationIgnored private var observation: Task<Void, Never>?
    /// The pre-rail migration went out this session (at most once, so an
    /// owner that refuses it is not asked again on every fetch).
    @ObservationIgnored private var migrationSent = false

    init(remote: (any SidebarLayoutRemote)? = nil, onRefused: @escaping @MainActor (String) -> Void = { _ in },
         prototypeEnabled: @escaping @MainActor () -> Bool = {
             DevTools.isEnabled && SidebarSectionTunables.localPrototype.override == true
         },
         railShown: @escaping @MainActor () -> Bool = { DesignSettings.shared.rail != .off }) {
        self.remote = remote
        self.onRefused = onRefused
        self.prototypeEnabled = prototypeEnabled
        self.railShown = railShown
    }

    isolated deinit {
        observation?.cancel()
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
    }

    private var usesOwner: Bool { remote?.isAvailable ?? false }

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
                    self.onRefused(String(describing: error))
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
            self?.adopt(confirmed)
            self?.recompute()
            self?.migrateIfNeeded()
        }
    }

    /// A stored layout that still equals the pre-rail default moves to the
    /// rail default (`SidebarLayoutDocument.railMigrationOps`) through
    /// ordinary intents, so the owner applies and syncs it like any edit. A
    /// layout the user changed is never touched. Waits for a quiet log, so
    /// it reads the owner's layout rather than one with the user's edits in
    /// flight.
    private func migrateIfNeeded() {
        // With the rail off the sidebar shows the sections itself, where the
        // pre-rail layout is the better one.
        guard !migrationSent, pending.isEmpty, railShown() else { return }
        let ops = mirror.railMigrationOps
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
