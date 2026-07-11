import AppKit
import CmuxUpdater
import CmuxUpdaterUI

extension AppDelegate: UpdateActionDelegate, UpdateActionsHost {
    func updaterRequestsRetryCheckForUpdates() {
        checkForUpdates(nil)
    }

    func updaterPreparesToRelaunchApplication() async {
        _ = await terminationResumeIndexCoordinator.loadForNewTerminationAttempt()
    }

    func updaterAbandonsRelaunchPreparation() {
        terminationResumeIndexCoordinator.invalidate()
    }

    func updaterWillRelaunchApplication() {
        persistSessionForUpdateRelaunch()
        TerminalController.shared.stop()
        NSApp.invalidateRestorableState()
        for window in NSApp.windows {
            window.invalidateRestorableState()
        }
    }

    func attemptUpdate() {
        attemptUpdate(nil)
    }

    var updateLogPath: String {
        updateLog.logPath()
    }

    private func persistSessionForUpdateRelaunch() {
        isTerminatingApp = true
        let resumeIndexResolver = UpdateRelaunchResumeIndexResolver(
            cachedIndexes: { SharedLiveAgentIndex.shared.cachedResumeIndexes() }
        )
        let resumeIndexes = resumeIndexResolver.resolve(
            coordinatedBy: terminationResumeIndexCoordinator.resolution()
        )
        _ = saveSessionSnapshotIncludingProcessDetectedIndexes(
            includeScrollback: true,
            removeWhenEmpty: false,
            resolvedResumeIndexAuthority: .completed(resumeIndexes)
        )
        ClosedItemHistoryStore.shared.flushPendingSaves()
    }
}
