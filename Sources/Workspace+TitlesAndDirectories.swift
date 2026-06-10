import Foundation
import SwiftUI
import AppKit
import Bonsplit
import CMUXAgentLaunch
import CmuxSocketControl
import Combine
import CryptoKit
import Darwin
import Network
import CoreText


// MARK: - Title management and directory updates
extension Workspace {
    enum PanelShellActivityState: String {
        case unknown
        case promptIdle
        case commandRunning
    }

    var hasCustomTitle: Bool {
        let trimmed = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !trimmed.isEmpty
    }

    var hasCustomDescription: Bool {
        Self.normalizedCustomDescription(customDescription) != nil
    }

    func applyProcessTitle(_ title: String) {
        if processTitle != title {
            processTitle = title
        }
        guard customTitle == nil else { return }
        guard self.title != title else { return }
#if DEBUG
        cmuxDebugLog(
            "workspace.title.applyProcess workspace=\(id.uuidString.prefix(5)) " +
            "from=\"\(debugWorkspaceDescriptionPreview(self.title, limit: 80))\" " +
            "to=\"\(debugWorkspaceDescriptionPreview(title, limit: 80))\""
        )
#endif
        self.title = title
    }

    func setCustomColor(_ hex: String?) {
        if let hex {
            customColor = WorkspaceTabColorSettings.normalizedHex(hex)
        } else {
            customColor = nil
        }
    }

    func setTerminalScrollBarHidden(_ hidden: Bool) {
        guard terminalScrollBarHidden != hidden else { return }
        terminalScrollBarHidden = hidden
        NotificationCenter.default.post(
            name: Self.terminalScrollBarHiddenDidChangeNotification,
            object: self
        )
    }

    private static func normalizedCustomDescription(_ description: String?) -> String? {
        let normalizedLineEndings = description?
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let trimmed = normalizedLineEndings?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        return normalizedLineEndings
    }

    func setCustomTitle(_ title: String?) {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            customTitle = nil
            self.title = processTitle
        } else {
            customTitle = trimmed
            self.title = trimmed
        }
    }

    func setCustomDescription(_ description: String?) {
        let normalizedDescription = Self.normalizedCustomDescription(description)
#if DEBUG
        let inputNewlines = description?.reduce(into: 0) { count, character in
            if character == "\n" { count += 1 }
        } ?? 0
        let normalizedNewlines = normalizedDescription?.reduce(into: 0) { count, character in
            if character == "\n" { count += 1 }
        } ?? 0
        cmuxDebugLog(
            "workspace.customDescription.update workspace=\(id.uuidString.prefix(8)) " +
            "inputLen=\((description as NSString?)?.length ?? 0) " +
            "inputNewlines=\(inputNewlines) " +
            "normalizedLen=\((normalizedDescription as NSString?)?.length ?? 0) " +
            "normalizedNewlines=\(normalizedNewlines) " +
            "input=\"\(debugWorkspaceDescriptionPreview(description))\" " +
            "normalized=\"\(debugWorkspaceDescriptionPreview(normalizedDescription))\""
        )
#endif
        customDescription = normalizedDescription
    }

    // MARK: - Directory Updates

    enum PanelDirectoryUpdateSource {
        case liveReport
        case restoredSnapshotMetadata
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

    func configTrackingDirectory(for panelId: UUID?) -> String? {
        if let panelId {
            for candidate in [
                panelDirectories[panelId],
                terminalPanel(for: panelId)?.requestedWorkingDirectory
            ] {
                let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }

        let trimmedCurrentDirectory = currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedCurrentDirectory.isEmpty ? nil : trimmedCurrentDirectory
    }

    @discardableResult
    func updatePanelDirectory(panelId: UUID, directory: String) -> Bool {
        updatePanelDirectory(panelId: panelId, directory: directory, source: .liveReport)
    }

    @discardableResult
    func updatePanelDirectory(
        panelId: UUID,
        directory: String,
        source: PanelDirectoryUpdateSource
    ) -> Bool {
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if source == .liveReport,
           shouldIgnoreRestoredGuardedDirectoryReport(panelId: panelId, reportedDirectory: trimmed) {
            return false
        }
        if panelDirectories[panelId] != trimmed {
            panelDirectories[panelId] = trimmed
        }
        // Update current directory if this is the focused panel
        if panelId == focusedPanelId {
            if surfaceTabBarDirectory != trimmed {
                surfaceTabBarDirectory = trimmed
            }
            if currentDirectory != trimmed {
                currentDirectory = trimmed
            }
        }
        return true
    }

    private func shouldIgnoreRestoredGuardedDirectoryReport(
        panelId: UUID,
        reportedDirectory: String
    ) -> Bool {
        guard let restoredDirectory = restoredGuardedWorkingDirectoriesByPanelId[panelId] else {
            return false
        }

        if reportedDirectory == restoredDirectory {
            restoredGuardedWorkingDirectoriesByPanelId.removeValue(forKey: panelId)
            return false
        }

        let missingVolumeRoot = Self.unmountedVolumeRoot(for: restoredDirectory)
        guard missingVolumeRoot != nil else {
            restoredGuardedWorkingDirectoriesByPanelId.removeValue(forKey: panelId)
            return false
        }

#if DEBUG
        cmuxDebugLog(
            "session.restore.cwdReport.ignored panel=\(panelId.uuidString.prefix(5)) " +
            "missingVolume=\(missingVolumeRoot ?? "") saved=\(restoredDirectory) reported=\(reportedDirectory)"
        )
#endif
        return true
    }

    func updatePanelShellActivityState(panelId: UUID, state: PanelShellActivityState) {
        guard panels[panelId] != nil else { return }
        let previousState = panelShellActivityStates[panelId] ?? .unknown
        guard previousState != state else { return }
        panelShellActivityStates[panelId] = state
        if let restoredAgent = restoredAgentSnapshotsByPanelId[panelId] {
            updateRestoredAgentResumeState(
                panelId: panelId,
                restoredAgent: restoredAgent,
                shellState: state
            )
        }
#if DEBUG
        cmuxDebugLog(
            "surface.shellState workspace=\(id.uuidString.prefix(5)) " +
            "panel=\(panelId.uuidString.prefix(5)) from=\(previousState.rawValue) to=\(state.rawValue)"
        )
#endif
    }

}
