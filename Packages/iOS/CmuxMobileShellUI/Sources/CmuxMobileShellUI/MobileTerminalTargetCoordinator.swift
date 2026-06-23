#if os(iOS)
import CMUXMobileCore
import CmuxMobileShell
import CmuxMobileShellModel
import Foundation
import Observation

/// Owns external requests to display a terminal surface.
///
/// Push notification taps and attach URLs both name a workspace and optionally
/// a terminal. Those requests can arrive before the shell store exists, before
/// the Mac workspace list is loaded, or before a terminal snapshot is present.
/// This coordinator parks the target until it can be applied through one path.
@MainActor
@Observable
public final class MobileTerminalTargetCoordinator {
    /// The origin of an external request to show a terminal.
    public enum Source: String, Sendable {
        case notification
        case attachURL = "attach_url"
    }

    private struct PendingTarget {
        let workspaceId: String?
        let surfaceId: String?
        let source: Source
        let createdAt: Date
    }

    @ObservationIgnored private weak var store: CMUXMobileShellStore?
    @ObservationIgnored private var pendingTarget: PendingTarget?
    @ObservationIgnored private let analytics: any AnalyticsEmitting
    @ObservationIgnored private let now: @MainActor () -> Date

    /// Bounded so a target from long ago cannot yank the user out of whatever
    /// they navigated to in the meantime, but generous enough to cover cold
    /// launch plus sign-in plus a slow attach.
    private static let pendingTargetLifetime: TimeInterval = 120

    public init(
        analytics: any AnalyticsEmitting = NoopAnalytics(),
        now: @escaping @MainActor () -> Date = Date.init
    ) {
        self.analytics = analytics
        self.now = now
    }

    /// Point routing at the active store, called by the root view on appear.
    public func bind(store: CMUXMobileShellStore) {
        self.store = store
        applyPendingTargetIfReady()
    }

    /// Re-apply a parked target once the workspace topology may have changed.
    public func workspacesDidChange() {
        applyPendingTargetIfReady()
    }

    /// Navigate to an externally requested workspace/terminal target.
    public func openTarget(
        workspaceId: String?,
        surfaceId: String?,
        source: Source
    ) {
        pendingTarget = PendingTarget(
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            source: source,
            createdAt: now()
        )
        applyPendingTargetIfReady()
    }

    private func applyPendingTargetIfReady() {
        guard let pending = pendingTarget else { return }
        guard now().timeIntervalSince(pending.createdAt) < Self.pendingTargetLifetime else {
            pendingTarget = nil
            analytics.capture("ios_terminal_target_navigation_failed", [
                "source": .string(pending.source.rawValue),
                "reason": .string("expired"),
            ])
            return
        }
        guard let store else { return }

        let workspaceTarget: MobileWorkspacePreview.ID
        if let workspaceId = pending.workspaceId {
            workspaceTarget = MobileWorkspacePreview.ID(rawValue: workspaceId)
            guard store.workspaces.contains(where: { $0.id == workspaceTarget }) else { return }
        } else if let surfaceId = pending.surfaceId {
            guard let owner = store.workspaceID(containingSurfaceID: surfaceId) else { return }
            workspaceTarget = owner
        } else {
            pendingTarget = nil
            return
        }

        if let surfaceId = pending.surfaceId,
           !store.workspace(workspaceTarget, containsSurfaceID: surfaceId) {
            store.navigateToWorkspaceForTerminalTarget(workspaceTarget)
            pendingTarget = PendingTarget(
                workspaceId: nil,
                surfaceId: surfaceId,
                source: pending.source,
                createdAt: pending.createdAt
            )
            return
        }

        store.navigateToWorkspaceForTerminalTarget(workspaceTarget)
        if let surfaceId = pending.surfaceId {
            store.selectTerminal(MobileTerminalPreview.ID(rawValue: surfaceId))
        }
        pendingTarget = nil
        analytics.capture("ios_terminal_target_navigation_resolved", [
            "source": .string(pending.source.rawValue),
            "resolved_workspace": .bool(pending.workspaceId != nil),
            "resolved_surface": .bool(pending.surfaceId != nil),
        ])
    }
}
#endif
