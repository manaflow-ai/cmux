import AppKit
import CmuxSocketControl
import Bonsplit
import Combine
@_spi(CmuxHostTransport) import CmuxExtensionKit
import CmuxSidebarProviderKit
import CmuxExtensionSidebarExamples
import CmuxSettings
import CmuxSettingsUI
import CmuxSidebarRemoteRender
import CmuxSwiftRender
import CmuxSwiftRenderUI
import CmuxUpdater
import CmuxUpdaterUI
import ImageIO
import Observation
import SwiftUI
import ObjectiveC
import UniformTypeIdentifiers
import WebKit


// MARK: - Command palette selection state and scroll anchoring
extension ContentView {
    var focusedPanelContext: (workspace: Workspace, panelId: UUID, panel: any Panel)? {
        guard let workspace = tabManager.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let panel = workspace.panels[panelId] else {
            return nil
        }
        return (workspace, panelId, panel)
    }

    private static func commandPaletteWorkspaceDisplayName(_ workspace: Workspace) -> String {
        let custom = workspace.customTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !custom.isEmpty {
            return custom
        }
        let title = workspace.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? String(localized: "workspace.displayName.fallback", defaultValue: "Workspace") : title
    }

    func workspaceDisplayName(_ workspace: Workspace) -> String {
        Self.commandPaletteWorkspaceDisplayName(workspace)
    }

    func panelDisplayName(workspace: Workspace, panelId: UUID, fallback: String) -> String {
        let title = workspace.panelTitle(panelId: panelId)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !title.isEmpty {
            return title
        }
        let trimmedFallback = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedFallback.isEmpty ? String(localized: "panel.displayName.fallback", defaultValue: "Tab") : trimmedFallback
    }

    func commandPaletteSelectedIndex(resultCount: Int) -> Int {
        guard resultCount > 0 else { return 0 }
        return min(max(commandPaletteSelectedResultIndex, 0), resultCount - 1)
    }

    static func commandPaletteResolvedSelectionIndex(
        preferredCommandID: String?,
        fallbackSelectedIndex: Int,
        resultIDs: [String]
    ) -> Int {
        guard !resultIDs.isEmpty else { return 0 }
        if let preferredCommandID,
           let anchoredIndex = resultIDs.firstIndex(of: preferredCommandID) {
            return anchoredIndex
        }
        return min(max(fallbackSelectedIndex, 0), resultIDs.count - 1)
    }

    static func commandPaletteSelectionAnchorCommandID(
        selectedIndex: Int,
        resultIDs: [String]
    ) -> String? {
        guard !resultIDs.isEmpty else { return nil }
        let resolvedIndex = min(max(selectedIndex, 0), resultIDs.count - 1)
        return resultIDs[resolvedIndex]
    }

    private static func commandPalettePendingActivationRequestID(
        _ pendingActivation: CommandPalettePendingActivation?
    ) -> UInt64? {
        switch pendingActivation {
        case .selected(let requestID, _, _):
            return requestID
        case .command(let requestID, _):
            return requestID
        case nil:
            return nil
        }
    }

    static func commandPalettePendingActivation(
        _ pendingActivation: CommandPalettePendingActivation?,
        rebasedTo requestID: UInt64
    ) -> CommandPalettePendingActivation? {
        switch pendingActivation {
        case .selected(_, let fallbackSelectedIndex, let preferredCommandID):
            return .selected(
                requestID: requestID,
                fallbackSelectedIndex: fallbackSelectedIndex,
                preferredCommandID: preferredCommandID
            )
        case .command(_, let commandID):
            return .command(requestID: requestID, commandID: commandID)
        case nil:
            return nil
        }
    }

    static func commandPaletteResolvedPendingActivation(
        _ pendingActivation: CommandPalettePendingActivation?,
        requestID: UInt64,
        resultIDs: [String]
    ) -> CommandPaletteResolvedActivation? {
        switch pendingActivation {
        case .selected(let activationRequestID, let fallbackSelectedIndex, let preferredCommandID):
            guard activationRequestID == requestID else { return nil }
            let resolvedIndex = commandPaletteResolvedSelectionIndex(
                preferredCommandID: preferredCommandID,
                fallbackSelectedIndex: fallbackSelectedIndex,
                resultIDs: resultIDs
            )
            return .selected(index: resolvedIndex)
        case .command(let activationRequestID, let commandID):
            guard activationRequestID == requestID, resultIDs.contains(commandID) else { return nil }
            return .command(commandID: commandID)
        case nil:
            return nil
        }
    }

    static func commandPalettePendingActivationResolution(
        _ pendingActivation: CommandPalettePendingActivation?,
        requestID: UInt64,
        resultIDs: [String]
    ) -> CommandPalettePendingActivationResolutionResult {
        CommandPalettePendingActivationResolutionResult(
            resolvedActivation: commandPaletteResolvedPendingActivation(
                pendingActivation,
                requestID: requestID,
                resultIDs: resultIDs
            ),
            shouldClearPendingActivation: commandPalettePendingActivationRequestID(pendingActivation) == requestID
        )
    }

    static func commandPaletteContextFingerprint(
        boolValues: [String: Bool],
        stringValues: [String: String]
    ) -> Int {
        var hasher = Hasher()
        for key in boolValues.keys.sorted() {
            hasher.combine(key)
            hasher.combine(boolValues[key] ?? false)
        }
        for key in stringValues.keys.sorted() {
            hasher.combine(key)
            hasher.combine(stringValues[key] ?? "")
        }
        return hasher.finalize()
    }

    static func commandPaletteSwitcherFingerprint(
        windowContexts: [CommandPaletteSwitcherFingerprintContext]
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(windowContexts.count)
        for context in windowContexts {
            hasher.combine(context.windowId)
            hasher.combine(context.windowLabel)
            hasher.combine(context.selectedWorkspaceId)
            hasher.combine(context.workspaces.count)
            for workspace in context.workspaces {
                hasher.combine(workspace.id)
                hasher.combine(workspace.displayName)
                combineCommandPaletteSwitcherSearchMetadata(workspace.metadata, into: &hasher)
                hasher.combine(workspace.surfaces.count)
                for surface in workspace.surfaces {
                    hasher.combine(surface.id)
                    hasher.combine(surface.displayName)
                    hasher.combine(surface.kindLabel)
                    combineCommandPaletteSwitcherSearchMetadata(surface.metadata, into: &hasher)
                }
            }
        }
        return hasher.finalize()
    }

    private static func combineCommandPaletteSwitcherSearchMetadata(
        _ metadata: CommandPaletteSwitcherSearchMetadata,
        into hasher: inout Hasher
    ) {
        hasher.combine(metadata.directories.count)
        for directory in metadata.directories {
            hasher.combine(directory)
        }
        hasher.combine(metadata.branches.count)
        for branch in metadata.branches {
            hasher.combine(branch)
        }
        hasher.combine(metadata.ports.count)
        for port in metadata.ports {
            hasher.combine(port)
        }
        hasher.combine(metadata.description ?? "")
    }

    static func commandPaletteScrollPositionAnchor(
        selectedIndex: Int,
        resultCount: Int
    ) -> UnitPoint? {
        guard resultCount > 0 else { return nil }
        if selectedIndex <= 0 { return UnitPoint.top }
        if selectedIndex >= resultCount - 1 { return UnitPoint.bottom }
        return nil
    }

    func updateCommandPaletteScrollTarget(resultCount: Int, animated: Bool) {
        guard resultCount > 0 else {
            commandPaletteScrollTargetIndex = nil
            commandPaletteScrollTargetAnchor = nil
            return
        }

        let selectedIndex = commandPaletteSelectedIndex(resultCount: resultCount)
        commandPaletteScrollTargetAnchor = Self.commandPaletteScrollPositionAnchor(
            selectedIndex: selectedIndex,
            resultCount: resultCount
        )

        let assignTarget = {
            commandPaletteScrollTargetIndex = selectedIndex
        }
        if animated {
            withAnimation(.easeOut(duration: 0.1)) {
                assignTarget()
            }
        } else {
            assignTarget()
        }
    }

    private func syncCommandPaletteSelectionAnchor(resultIDs: [String]) {
        commandPaletteSelectionAnchorCommandID = Self.commandPaletteSelectionAnchorCommandID(
            selectedIndex: commandPaletteSelectedResultIndex,
            resultIDs: resultIDs
        )
    }

    func syncCommandPaletteSelectionAnchorFromCurrentResults() {
        syncCommandPaletteSelectionAnchor(resultIDs: cachedCommandPaletteResults.map(\.id))
    }

    private func syncCommandPaletteSelectionAnchorFromVisibleResults() {
        syncCommandPaletteSelectionAnchor(resultIDs: commandPaletteVisibleResults.map(\.id))
    }

    func moveCommandPaletteSelection(by delta: Int) {
        let count = commandPaletteVisibleResults.count
        guard count > 0 else {
            NSSound.beep()
            return
        }
        let current = commandPaletteSelectedIndex(resultCount: count)
        commandPaletteSelectedResultIndex = min(max(current + delta, 0), count - 1)
        if commandPaletteHasCurrentResolvedResults {
            syncCommandPaletteSelectionAnchorFromCurrentResults()
        } else {
            syncCommandPaletteSelectionAnchorFromVisibleResults()
        }
        updateCommandPaletteScrollTarget(resultCount: count, animated: true)
        syncCommandPaletteOverlayCommandListState()
        syncCommandPaletteDebugStateForObservedWindow()
    }

    func forwardCommandPaletteUnhandledNavigationKeyToFocusedTerminal(_ event: NSEvent) -> Bool {
        guard let target = commandPaletteRestoreFocusTarget,
              target.intent == .terminal(.surface),
              let workspace = tabManager.tabs.first(where: { $0.id == target.workspaceId }),
              let terminalPanel = workspace.panels[target.panelId] as? TerminalPanel else { return false }
        terminalPanel.hostedView.forwardKeyDownToSurface(event); return true
    }

    static func commandPaletteShouldPopRenameInputOnDelete(
        renameDraft: String,
        modifiers: EventModifiers
    ) -> Bool {
        let blockedModifiers: EventModifiers = [.command, .control, .option, .shift]
        guard modifiers.intersection(blockedModifiers).isEmpty else { return false }
        return renameDraft.isEmpty
    }

    func handleCommandPaletteRenameDeleteBackward(
        modifiers: EventModifiers
    ) -> BackportKeyPressResult {
        guard case .renameInput = commandPaletteMode else { return .ignored }
        let blockedModifiers: EventModifiers = [.command, .control, .option, .shift]
        guard modifiers.intersection(blockedModifiers).isEmpty else { return .ignored }

        if Self.commandPaletteShouldPopRenameInputOnDelete(
            renameDraft: commandPaletteRenameDraft,
            modifiers: modifiers
        ) {
            commandPaletteMode = .commands
            resetCommandPaletteSearchFocus()
            syncCommandPaletteDebugStateForObservedWindow()
            return .handled
        }

        if let window = observedWindow ?? NSApp.keyWindow ?? NSApp.mainWindow,
           let editor = window.firstResponder as? NSTextView,
           editor.isFieldEditor {
            editor.deleteBackward(nil)
            commandPaletteRenameDraft = editor.string
        } else if !commandPaletteRenameDraft.isEmpty {
            commandPaletteRenameDraft.removeLast()
        }

        syncCommandPaletteDebugStateForObservedWindow()
        return .handled
    }

    var commandPaletteHasCurrentResolvedResults: Bool {
        !isCommandPaletteSearchPending && commandPaletteResolvedSearchRequestID == commandPaletteSearchRequestID
    }

    var commandPaletteShouldShowEmptyState: Bool {
        guard commandPaletteVisibleResults.isEmpty else { return false }
        if commandPaletteHasCurrentResolvedResults {
            return true
        }

        return CommandPaletteSearchOrchestrator.shouldPreserveEmptyStateWhileSearchPending(
            isSearchPending: isCommandPaletteSearchPending,
            visibleResultsScopeMatches: commandPaletteVisibleResultsScope == commandPaletteListScope,
            resolvedSearchScopeMatches: commandPaletteResolvedSearchScope == commandPaletteListScope,
            resolvedSearchFingerprintMatches: commandPaletteResolvedSearchFingerprint == commandPaletteVisibleResultsFingerprint,
            resolvedResultsAreEmpty: cachedCommandPaletteResults.isEmpty
        )
    }

}
