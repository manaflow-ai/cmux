import Foundation

extension Workspace {
    struct RestoredWorkingDirectoryGuard {
        enum Phase: Equatable {
            case awaitingInitialReport
            case confirmed
        }

        let directory: String
        var phase: Phase = .awaitingInitialReport
    }

    func acceptedRestoredGuardedDirectoryReport(
        panelId: UUID,
        reportedDirectory: String
    ) -> String? {
        guard var guardState = restoredGuardedWorkingDirectoriesByPanelId[panelId] else {
            return reportedDirectory
        }
        let restoredDirectory = guardState.directory

        if Self.pathsReferToSameDirectory(reportedDirectory, restoredDirectory) {
            // Preserve the saved logical spelling when login resolves a symlink.
            guardState.phase = .confirmed
            restoredGuardedWorkingDirectoriesByPanelId[panelId] = guardState
            return restoredDirectory
        }

        if Self.unmountedVolumeRoot(for: restoredDirectory) != nil {
            // Keep guarding until the restored volume remounts and reports its cwd (#5278).
#if DEBUG
            cmuxDebugLog(
                "session.restore.cwdReport.ignored panel=\(panelId.uuidString.prefix(5)) " +
                "saved=\(restoredDirectory) reported=\(reportedDirectory)"
            )
#endif
            return nil
        }

        restoredGuardedWorkingDirectoriesByPanelId.removeValue(forKey: panelId)
        if guardState.phase == .confirmed {
            return reportedDirectory
        }
        // Ignore the first fallback cwd only if the restored directory still exists (#6617).
        var restoredDirectoryIsDirectory: ObjCBool = false
        let restoredDirectoryStillExists = FileManager.default.fileExists(
            atPath: restoredDirectory,
            isDirectory: &restoredDirectoryIsDirectory
        ) && restoredDirectoryIsDirectory.boolValue
        if !restoredDirectoryStillExists {
            restoredResumeSessionWorkingDirectoriesByPanelId.removeValue(forKey: panelId)
        }
#if DEBUG
        cmuxDebugLog(
            "session.restore.cwdReport.\(restoredDirectoryStillExists ? "ignoredOnce" : "accepted") " +
            "panel=\(panelId.uuidString.prefix(5)) saved=\(restoredDirectory) reported=\(reportedDirectory)"
        )
#endif
        return restoredDirectoryStillExists ? nil : reportedDirectory
    }

    static func unmountedVolumeRoot(
        for workingDirectory: String,
        fileManager: FileManager = .default
    ) -> String? {
        let trimmed = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let components = URL(fileURLWithPath: trimmed, isDirectory: true)
            .standardizedFileURL
            .pathComponents
        guard components.count >= 3,
              components[0] == "/",
              components[1] == "Volumes",
              !components[2].isEmpty else {
            return nil
        }

        let volumeRoot = "/Volumes/\(components[2])"
        return fileManager.fileExists(atPath: volumeRoot) ? nil : volumeRoot
    }

    private static func pathsReferToSameDirectory(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs { return true }
        let left = URL(fileURLWithPath: lhs, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL.path
        let right = URL(fileURLWithPath: rhs, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL.path
        return left == right
    }
}
