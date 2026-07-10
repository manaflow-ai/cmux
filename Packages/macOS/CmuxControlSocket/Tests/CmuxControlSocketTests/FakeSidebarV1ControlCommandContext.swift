import Foundation
@testable import CmuxControlSocket

@MainActor
final class FakeSidebarV1ControlCommandContext: ControlCommandContext {
    struct ScheduledDirectoryUpdate: Equatable {
        let scope: ControlSidebarPanelScope
        let directory: String
        let displayLabel: String?
    }

    var workspaceLoadingResult: ControlSidebarWorkspaceLoadingState?
    var workspaceLoadingCall: (tabArg: String?, key: String, on: Bool)?
    var tabManagerAvailable = true
    var directoryUpdateResult: ControlSidebarPanelWriteResolution = .done
    var directoryUpdateCall: (tabArg: String?, panelArg: String?, directory: String, displayLabel: String?)?

    // Each test owns one fake and drives it serially; unsafe isolation lets the
    // nonisolated worker-lane witnesses record calls without adding a lock.
    nonisolated(unsafe) private var mainHopCountStorage = 0
    nonisolated(unsafe) private var scheduledDirectoryUpdatesStorage: [ScheduledDirectoryUpdate] = []

    var mainHopCount: Int { mainHopCountStorage }
    var scheduledDirectoryUpdates: [ScheduledDirectoryUpdate] { scheduledDirectoryUpdatesStorage }

    nonisolated func controlSidebarOnMain<T: Sendable>(
        _ body: @MainActor (any ControlSidebarContext) -> T
    ) -> T {
        mainHopCountStorage += 1
        nonisolated(unsafe) let seam: any ControlSidebarContext = self
        if Thread.isMainThread {
            return MainActor.assumeIsolated { body(seam) }
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated { body(seam) }
        }
    }

    func controlSidebarTabManagerAvailable() -> Bool {
        tabManagerAvailable
    }

    nonisolated func controlSidebarScheduleScopedDirectoryUpdate(
        scope: ControlSidebarPanelScope,
        directory: String,
        displayLabel: String?
    ) {
        scheduledDirectoryUpdatesStorage.append(ScheduledDirectoryUpdate(
            scope: scope,
            directory: directory,
            displayLabel: displayLabel
        ))
    }

    func controlSidebarUpdateDirectory(
        tabArg: String?,
        panelArg: String?,
        directory: String,
        displayLabel: String?
    ) -> ControlSidebarPanelWriteResolution {
        directoryUpdateCall = (tabArg, panelArg, directory, displayLabel)
        return directoryUpdateResult
    }

    func controlSidebarSetWorkspaceLoading(
        tabArg: String?,
        key: String,
        on: Bool
    ) -> ControlSidebarWorkspaceLoadingState? {
        workspaceLoadingCall = (tabArg, key, on)
        return workspaceLoadingResult
    }
}
