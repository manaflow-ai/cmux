import Foundation
import CmuxNestedTopology
import CmuxSettings
import OSLog
import Observation

/// App-scoped host for nested topology attachment, read projection,
/// capability-gated focus, and session-snapshot restore (PR4–PR6).
///
/// Owns the ``NestedTopologyAttachmentCoordinator`` (actor) and a MainActor
/// read cache used by the sidebar. Provider descendants remain virtual under a
/// host terminal surface — never mirrored into Bonsplit / `Workspace.panels`.
@MainActor
@Observable
final class NestedTopologyController {
    nonisolated static let logger = Logger(subsystem: "com.cmuxterm.app", category: "NestedTopology")

    /// Attachment coordinator (provider I/O off the main actor).
    let coordinator: NestedTopologyAttachmentCoordinator

    /// Expanded host surfaces for the sidebar subtree (container-owned).
    private(set) var expandedHostSurfaceIDs: Set<UUID> = []

    /// Last projected sidebar subtrees keyed by host stable surface ID.
    private(set) var sidebarSubtreesByHostSurfaceID: [UUID: NestedSidebarSubtreeSnapshot] = [:]

    /// Last known persistence intents keyed by host stable surface ID (for session snapshots).
    private(set) var attachmentIntentsByHostSurfaceID: [UUID: NestedAttachmentIntentDescriptor] = [:]

    /// Host surface IDs per host workspace ID string (from last refresh).
    private var hostSurfacesByWorkspaceID: [String: Set<UUID>] = [:]

    private var readService = NestedTopologyReadService()
    private var refreshTask: Task<Void, Never>?
    private var restoreTasks: [UUID: Task<Void, Never>] = [:]
    private var closeTasks: [UUID: Task<Void, Never>] = [:]
    private let refreshBridge = NestedTopologyRefreshBridge()

    /// Synchronous read of the nested-topology beta flag (socket/AppKit paths).
    nonisolated static var isEnabled: Bool {
        let key = SettingCatalog().betaFeatures.nestedTopology
        return Bool.decodeFromUserDefaults(UserDefaults.standard.object(forKey: key.userDefaultsKey))
            ?? key.defaultValue
    }

    init(coordinator: NestedTopologyAttachmentCoordinator? = nil) {
        let handoffDirectory = Self.defaultHandoffDirectory()
        if let coordinator {
            self.coordinator = coordinator
        } else {
            let bridge = refreshBridge
            self.coordinator = NestedTopologyAttachmentCoordinator(
                handoff: NestedPluginWriterHandoff(directoryURL: handoffDirectory),
                telemetrySink: { _ in bridge.schedule() }
            )
        }
        refreshBridge.handler = { [weak self] in
            self?.scheduleSidebarRefresh()
        }
    }

    /// Lists attachments for the control-socket read API.
    func listAttachments(
        hostStableSurfaceID: UUID? = nil,
        hostWorkspaceID: String? = nil
    ) async -> NestedTopologyReadListResult {
        let attachments = await coordinator.allAttachments()
        let result = readService.list(
            attachments: attachments,
            hostStableSurfaceID: hostStableSurfaceID,
            hostWorkspaceID: hostWorkspaceID
        )
        rebuildSidebarCache(from: attachments)
        return result
    }

    /// Refreshes MainActor sidebar snapshots from the coordinator.
    func refreshSidebarSnapshots() async {
        guard Self.isEnabled else {
            sidebarSubtreesByHostSurfaceID = [:]
            hostSurfacesByWorkspaceID = [:]
            return
        }
        let attachments = await coordinator.allAttachments()
        rebuildSidebarCache(from: attachments)
    }

    /// Schedules a coalesced sidebar refresh (diff-friendly; no per-frame thrash).
    func scheduleSidebarRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            await self.refreshSidebarSnapshots()
        }
    }

    /// Toggles expansion for one host surface's nested subtree.
    func toggleExpanded(hostStableSurfaceID: UUID) {
        if expandedHostSurfaceIDs.contains(hostStableSurfaceID) {
            expandedHostSurfaceIDs.remove(hostStableSurfaceID)
        } else {
            expandedHostSurfaceIDs.insert(hostStableSurfaceID)
        }
        if let snapshot = sidebarSubtreesByHostSurfaceID[hostStableSurfaceID] {
            sidebarSubtreesByHostSurfaceID[hostStableSurfaceID] = NestedSidebarSubtreeSnapshot(
                hostStableSurfaceID: snapshot.hostStableSurfaceID,
                attachmentID: snapshot.attachmentID,
                providerKind: snapshot.providerKind,
                connectionState: snapshot.connectionState,
                isStale: snapshot.isStale,
                isExpanded: expandedHostSurfaceIDs.contains(hostStableSurfaceID),
                roots: snapshot.roots
            )
        } else {
            scheduleSidebarRefresh()
        }
    }

    /// Focuses a nested node via the capability-gated coordinator path.
    ///
    /// Used by sidebar row selection and `nested.node.focus`. Does not mutate
    /// Bonsplit / Ghostty state; topology updates come from provider events.
    @discardableResult
    func focusNode(_ request: NestedNodeFocusRequest) async throws -> NestedNodeFocusResult {
        let result = try await coordinator.focusNode(request)
        scheduleSidebarRefresh()
        return result
    }

    /// Sidebar convenience: focus a node under a known host surface (user confirmed).
    func focusSidebarNode(hostStableSurfaceID: UUID, nodeID: NestedNodeID) {
        guard Self.isEnabled else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await self.focusNode(
                    NestedNodeFocusRequest(
                        hostStableSurfaceID: hostStableSurfaceID,
                        nodeID: nodeID,
                        expectedAttachmentID: self.sidebarSubtreesByHostSurfaceID[hostStableSurfaceID]?.attachmentID,
                        expectedProviderInstanceID: nodeID.providerInstanceID,
                        authorization: .userConfirmed
                    )
                )
            } catch {
                Self.logger.error("nested focus failed: \((error as? NestedAttachmentError)?.telemetryErrorClass ?? "focus_failed", privacy: .private)")
            }
        }
    }

    /// Sidebar snapshot for a host surface, if any attachment exists.
    func sidebarSubtree(for hostStableSurfaceID: UUID) -> NestedSidebarSubtreeSnapshot? {
        guard Self.isEnabled else { return nil }
        return sidebarSubtreesByHostSurfaceID[hostStableSurfaceID]
    }

    /// Nested subtrees bound to a workspace (by host workspace ID string).
    func sidebarSubtrees(forWorkspaceID workspaceID: UUID) -> [NestedSidebarSubtreeSnapshot] {
        guard Self.isEnabled else { return [] }
        let keys = [
            workspaceID.uuidString,
            workspaceID.uuidString.lowercased(),
            workspaceID.uuidString.uppercased(),
        ]
        var hostIDs = Set<UUID>()
        for key in keys {
            if let ids = hostSurfacesByWorkspaceID[key] {
                hostIDs.formUnion(ids)
            }
        }
        return hostIDs
            .compactMap { sidebarSubtreesByHostSurfaceID[$0] }
            .sorted { $0.hostStableSurfaceID.uuidString < $1.hostStableSurfaceID.uuidString }
    }

    /// Notifies that a host surface moved workspaces (preserves attachment).
    func hostSurfaceMoved(hostStableSurfaceID: UUID, toWorkspaceID: String) async {
        await coordinator.noteHostSurfaceMoved(
            hostStableSurfaceID: hostStableSurfaceID,
            toWorkspaceID: toWorkspaceID
        )
        scheduleSidebarRefresh()
    }

    /// Detaches when the host surface closes (no provider stop / child closes).
    func hostSurfaceClosed(hostStableSurfaceID: UUID) async {
        cancelPendingRestore(hostStableSurfaceID: hostStableSurfaceID)
        await coordinator.noteHostSurfaceClosed(hostStableSurfaceID: hostStableSurfaceID)
        expandedHostSurfaceIDs.remove(hostStableSurfaceID)
        sidebarSubtreesByHostSurfaceID.removeValue(forKey: hostStableSurfaceID)
        attachmentIntentsByHostSurfaceID.removeValue(forKey: hostStableSurfaceID)
        closeTasks[hostStableSurfaceID] = nil
        scheduleSidebarRefresh()
    }

    /// Enqueues a cancellable host-surface close so panel teardown owns the task.
    func enqueueHostSurfaceClosed(hostStableSurfaceID: UUID) {
        closeTasks[hostStableSurfaceID]?.cancel()
        closeTasks[hostStableSurfaceID] = Task { @MainActor [weak self] in
            await self?.hostSurfaceClosed(hostStableSurfaceID: hostStableSurfaceID)
        }
    }

    /// Tears down all attachments (app/window teardown).
    func teardown() async {
        for (_, task) in restoreTasks {
            task.cancel()
        }
        restoreTasks.removeAll()
        for (_, task) in closeTasks {
            task.cancel()
        }
        closeTasks.removeAll()
        await coordinator.teardown()
        expandedHostSurfaceIDs = []
        sidebarSubtreesByHostSurfaceID = [:]
        attachmentIntentsByHostSurfaceID = [:]
        hostSurfacesByWorkspaceID = [:]
    }

    /// Persistence intent for a host surface (session snapshot capture).
    ///
    /// Prefers the coordinator's published intent so a stale MainActor cache
    /// cannot persist an empty or outdated attachment.
    func attachmentIntent(for hostStableSurfaceID: UUID) -> NestedAttachmentIntentDescriptor? {
        guard Self.isEnabled else { return nil }
        if let published = coordinator.persistenceIntent(for: hostStableSurfaceID) {
            attachmentIntentsByHostSurfaceID[hostStableSurfaceID] = published
            return published
        }
        return attachmentIntentsByHostSurfaceID[hostStableSurfaceID]
    }

    /// Reads the coordinator's current attachment intent (fresh, not debounce-cached).
    func freshAttachmentIntent(for hostStableSurfaceID: UUID) async -> NestedAttachmentIntentDescriptor? {
        guard Self.isEnabled else { return nil }
        let attachments = await coordinator.allAttachments()
        rebuildSidebarCache(from: attachments)
        return attachmentIntentsByHostSurfaceID[hostStableSurfaceID]
    }

    /// Schedules deferred restore after a terminal panel + stable surface exist.
    ///
    /// Cancelled automatically when the host surface closes or the controller tears down.
    func scheduleRestoreAttachment(
        hostWorkspaceID: String,
        hostStableSurfaceID: UUID,
        intent: NestedAttachmentIntentDescriptor
    ) {
        guard Self.isEnabled else { return }
        cancelPendingRestore(hostStableSurfaceID: hostStableSurfaceID)
        attachmentIntentsByHostSurfaceID[hostStableSurfaceID] = intent
        let task = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            let record = await self.coordinator.restoreFromIntent(
                hostWorkspaceID: hostWorkspaceID,
                hostStableSurfaceID: hostStableSurfaceID,
                intent: intent
            )
            guard !Task.isCancelled else { return }
            if let nextIntent = record.sessionPersistenceIntent ?? record.pendingRestoreIntent {
                self.attachmentIntentsByHostSurfaceID[hostStableSurfaceID] = nextIntent
            }
            self.restoreTasks[hostStableSurfaceID] = nil
            self.scheduleSidebarRefresh()
        }
        restoreTasks[hostStableSurfaceID] = task
    }

    /// Cancels an in-flight restore for a host surface (panel closed mid-restore).
    func cancelPendingRestore(hostStableSurfaceID: UUID) {
        restoreTasks.removeValue(forKey: hostStableSurfaceID)?.cancel()
    }

    private func rebuildSidebarCache(from attachments: [NestedAttachmentRecord]) {
        var next: [UUID: NestedSidebarSubtreeSnapshot] = [:]
        var intents: [UUID: NestedAttachmentIntentDescriptor] = [:]
        var byWorkspace: [String: Set<UUID>] = [:]
        for attachment in attachments {
            let expanded = expandedHostSurfaceIDs.contains(attachment.hostStableSurfaceID)
            next[attachment.hostStableSurfaceID] = readService.sidebarSubtree(
                for: attachment,
                isExpanded: expanded
            )
            if let intent = attachment.sessionPersistenceIntent ?? attachment.pendingRestoreIntent {
                intents[attachment.hostStableSurfaceID] = intent
            }
            byWorkspace[attachment.hostWorkspaceID, default: []].insert(attachment.hostStableSurfaceID)
        }
        sidebarSubtreesByHostSurfaceID = next
        // Preserve intents for surfaces that still have a pending restore task
        // but have not yet published an attachment record.
        for (surfaceID, intent) in attachmentIntentsByHostSurfaceID where intents[surfaceID] == nil {
            if restoreTasks[surfaceID] != nil {
                intents[surfaceID] = intent
            }
        }
        attachmentIntentsByHostSurfaceID = intents
        hostSurfacesByWorkspaceID = byWorkspace
    }

    private static func defaultHandoffDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("nested-topology", isDirectory: true)
    }
}

/// Bridges actor telemetry callbacks to MainActor refresh without retaining cycles.
private final class NestedTopologyRefreshBridge: @unchecked Sendable {
    @MainActor var handler: (() -> Void)?

    nonisolated func schedule() {
        Task { @MainActor in
            self.handler?()
        }
    }
}
