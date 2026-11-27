#if os(iOS)
import CmuxMobileShell
import CmuxMobilePairedMac
import CmuxMobileShellModel
import Foundation

@MainActor
struct TaskComposerDirectoryCandidates {
    let store: CMUXMobileShellStore
    let selectedMacDeviceID: String
    let selectedMacInstanceTag: String?
    let selectedTemplate: MobileTaskTemplate?

    func make() -> [MobileTaskDirectoryCandidate] {
        let selectedPairingID = MobilePairedMac.pairingID(
            macDeviceID: selectedMacDeviceID,
            instanceTag: selectedMacInstanceTag
        )
        var candidates: [MobileTaskDirectoryCandidate] = []
        append(
            selectedTemplate?.defaultDirectory,
            source: .templateDefault,
            context: selectedTemplate?.name,
            to: &candidates
        )
        append(
            store.taskTemplateStore?.lastDirectory(macDeviceID: selectedPairingID),
            source: .lastSuccessful,
            context: nil,
            to: &candidates
        )
        for recent in store.taskTemplateStore?.recentDirectories(macDeviceID: selectedPairingID) ?? [] {
            append(
                recent.path,
                source: .recentSuccessful,
                context: nil,
                lastUsedAt: recent.lastUsedAt,
                useCount: recent.useCount,
                to: &candidates
            )
        }

        let includeUnscoped = !selectedMacDeviceID.isEmpty
            && store.connectedMacDeviceID != nil
            && MobilePairedMac.pairingID(
            macDeviceID: selectedMacDeviceID,
            instanceTag: selectedMacInstanceTag
            ) == MobilePairedMac.pairingID(
                macDeviceID: store.connectedMacDeviceID ?? "",
                instanceTag: store.connectedMacInstanceTag
            )
        for workspace in store.workspaces where
            (workspace.macDeviceID.map {
                MobileWorkspaceListFilter.machineEntryMatches(
                    selectedPairingID,
                    deviceID: $0,
                    rowTag: workspace.macInstanceTag
                )
            } ?? false)
            || (workspace.macDeviceID == nil && includeUnscoped) {
            let isActiveWorkspace = workspace.id == store.selectedWorkspaceID
            append(
                workspace.currentDirectory,
                source: isActiveWorkspace ? .activeWorkspace : .openWorkspace,
                context: workspace.name,
                lastUsedAt: workspace.lastActivityAt,
                to: &candidates
            )
            for terminal in workspace.terminals {
                append(
                    terminal.currentDirectory,
                    source: isActiveWorkspace && terminal.isFocused ? .activeTerminal : .openTerminal,
                    context: "\(workspace.name) · \(terminal.name)",
                    lastUsedAt: workspace.lastActivityAt,
                    to: &candidates
                )
            }
        }

        append("~", source: .home, context: nil, to: &candidates)
        return candidates
    }

    private func append(
        _ rawPath: String?,
        source: MobileTaskDirectorySource,
        context: String?,
        lastUsedAt: Date? = nil,
        useCount: Int = 0,
        to candidates: inout [MobileTaskDirectoryCandidate]
    ) {
        guard let path = rawPath?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            return
        }
        candidates.append(MobileTaskDirectoryCandidate(
            path: path,
            source: source,
            context: context,
            lastUsedAt: lastUsedAt,
            useCount: useCount
        ))
    }
}
#endif
