import AppKit
import CmuxAuthRuntime
import CmuxControlSocket
import CmuxSettings
import CmuxSettingsUI
import CmuxSocketControl
import CmuxUpdater
import CmuxUpdaterUI
import SwiftUI
import Bonsplit
import CMUXWorkstream
import CoreServices
import UserNotifications
import Sentry
import WebKit
import Combine
import ObjectiveC.runtime
import Darwin
import CmuxFoundation


// MARK: - ConfiguredGroupActionAsyncWorkspaceObserver
/// Short-lived helper that watches for the next workspace to appear in a
/// TabManager and joins it to a target group. Used by group `+` context-menu
/// actions whose underlying executor creates the workspace asynchronously
/// (cloudVM in particular launches `cmux vm new` and returns immediately).
/// Subscribes to `tabManager.$tabs` (the @Published source of truth that
/// `addWorkspace` updates, regardless of whether a NotificationCenter event
/// fired) so VM workspaces, dropped attaches, or any other slow async path
/// is caught. Self-clears on first match, group disappearance, or a process
/// completion signal that either names the created workspace or reports launch
/// failure.
@MainActor
final class ConfiguredGroupActionAsyncWorkspaceObserver {
    static var pending: [ObjectIdentifier: ConfiguredGroupActionAsyncWorkspaceObserver] = [:]
    let id = UUID()
    weak var tabManager: TabManager?
    private let storedKey: ObjectIdentifier
    let groupId: UUID
    let placement: WorkspaceGroupNewPlacement
    let referenceWorkspaceId: UUID?
    var knownIds: Set<UUID>
    private var subscription: AnyCancellable?

    @discardableResult
    static func install(
        tabManager: TabManager,
        groupId: UUID,
        knownIds: Set<UUID>,
        placement: WorkspaceGroupNewPlacement,
        referenceWorkspaceId: UUID?
    ) -> UUID {
        let key = ObjectIdentifier(tabManager)
        pending[key]?.dispose()
        let watcher = ConfiguredGroupActionAsyncWorkspaceObserver(
            tabManager: tabManager,
            groupId: groupId,
            placement: placement,
            referenceWorkspaceId: referenceWorkspaceId,
            knownIds: knownIds
        )
        pending[key] = watcher
        watcher.subscription = tabManager.$tabs
            .receive(on: DispatchQueue.main)
            .sink { [weak watcher] tabs in
                watcher?.checkForNewWorkspace(in: tabs)
            }
        return watcher.id
    }

    static func disposePending(tabManager: TabManager, observerId: UUID) {
        let key = ObjectIdentifier(tabManager)
        guard pending[key]?.id == observerId else { return }
        pending[key]?.dispose()
    }

    static func finishPending(tabManager: TabManager, observerId: UUID, workspaceId: UUID?) {
        let key = ObjectIdentifier(tabManager)
        guard let watcher = pending[key], watcher.id == observerId else { return }
        watcher.finish(workspaceId: workspaceId)
    }

    private init(
        tabManager: TabManager,
        groupId: UUID,
        placement: WorkspaceGroupNewPlacement,
        referenceWorkspaceId: UUID?,
        knownIds: Set<UUID>
    ) {
        self.tabManager = tabManager
        self.storedKey = ObjectIdentifier(tabManager)
        self.groupId = groupId
        self.placement = placement
        self.referenceWorkspaceId = referenceWorkspaceId
        self.knownIds = knownIds
    }

    private func checkForNewWorkspace(in tabs: [Workspace]) {
        guard let tabManager else { dispose(); return }
        guard tabManager.workspaceGroups.contains(where: { $0.id == groupId }) else {
            dispose()
            return
        }
        for tab in tabs where !knownIds.contains(tab.id) {
            tabManager.addWorkspaceToGroup(
                workspaceId: tab.id,
                groupId: groupId,
                placement: placement,
                referenceWorkspaceId: referenceWorkspaceId
            )
            dispose()
            return
        }
    }

    func finish(workspaceId: UUID?) {
        defer { dispose() }
        guard let workspaceId, let tabManager else { return }
        guard tabManager.workspaceGroups.contains(where: { $0.id == groupId }) else { return }
        guard tabManager.tabs.contains(where: { $0.id == workspaceId }) else { return }
        tabManager.addWorkspaceToGroup(
            workspaceId: workspaceId,
            groupId: groupId,
            placement: placement,
            referenceWorkspaceId: referenceWorkspaceId
        )
    }

    private func dispose() {
        subscription?.cancel()
        subscription = nil
        // Remove by the key recorded at install time. The weak `tabManager`
        // may already be nil here (window closed mid-watch), and walking it
        // would silently leak the entry in the static `pending` dictionary
        // for the rest of the app session.
        Self.pending.removeValue(forKey: storedKey)
    }
}

