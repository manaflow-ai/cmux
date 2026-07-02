import AppKit
import CmuxWorkspaces
import SwiftUI

extension TextBoxInputContainer {
    static let pendingProviderLaunchTimeoutSeconds: TimeInterval = 12

    var submitActions: [TextBoxSubmitAction] {
        if cachedSubmitActionsJSON == configuredSubmitActionsJSON {
            return cachedSubmitActions
        }
        return TerminalTextBoxInputSettings.submitActions(configuredJSON: configuredSubmitActionsJSON)
    }

    func refreshSubmitActionsCacheIfNeeded() {
        guard cachedSubmitActionsJSON != configuredSubmitActionsJSON else { return }
        cachedSubmitActions = TerminalTextBoxInputSettings.submitActions(configuredJSON: configuredSubmitActionsJSON)
        cachedSubmitActionsJSON = configuredSubmitActionsJSON
    }

    var submitActionImageCacheKeys: [String] {
        Self.submitActionImageCacheKeys(for: submitActions)
    }

    static func submitActionImageCacheKeys(
        for actions: [TextBoxSubmitAction],
        expandPath: (String) -> String = { NSString(string: $0).expandingTildeInPath }
    ) -> [String] {
        var seenKeys = Set<String>()
        var keys: [String] = []
        for action in actions.prefix(TextBoxSubmitActionImageSupport.maximumCachedImageCount) {
            guard let path = action.imagePath?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !path.isEmpty else {
                if let assetName = action.assetName?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !assetName.isEmpty {
                    let key = "asset:\(assetName)"
                    if seenKeys.insert(key).inserted {
                        keys.append(key)
                    }
                }
                continue
            }
            let key = "path:\(expandPath(path))"
            if seenKeys.insert(key).inserted {
                keys.append(key)
            }
        }
        return keys.sorted()
    }

    var submitActionImageCacheTaskKey: String {
        submitActionImageCacheKeys.joined(separator: "\u{1F}")
    }

    var selectedSubmitAction: TextBoxSubmitAction {
        Self.selectedSubmitAction(
            defaultSubmitActionID: effectiveSubmitActionID,
            submitActions: submitActions
        )
    }

    var effectiveSubmitActionID: String { selectedSubmitActionID ?? configuredDefaultSubmitActionID }

    static func selectedSubmitAction(
        defaultSubmitActionID: String,
        submitActions: [TextBoxSubmitAction]
    ) -> TextBoxSubmitAction {
        if defaultSubmitActionID == TextBoxSubmitAction.textEntryAction.id {
            return TextBoxSubmitAction.textEntryAction
        }
        if let selected = submitActions.first(where: { $0.id == defaultSubmitActionID }) {
            return selected
        }
        if !TextBoxSubmitAction.builtInActions.contains(where: { $0.id == defaultSubmitActionID }) {
            return TextBoxSubmitAction.textEntryAction
        }
        return submitActions.first { $0.id == TerminalTextBoxInputSettings.defaultSubmitActionID }
            ?? TextBoxSubmitAction.builtInActions[0]
    }

    var shouldForceTextEntrySubmit: Bool {
        Self.shouldForceTextEntrySubmit(
            allowsCommandTemplateSubmit: allowsCommandTemplateSubmit,
            terminalAgentContext: terminalAgentContext
        )
    }

    var isProviderLaunchAwaitingAgentOrCommand: Bool {
        pendingProviderLaunchAction != nil
    }

    var allowsSubmitActionSelection: Bool {
        Self.allowsSubmitActionSelection(
            pendingProviderLaunchAction: pendingProviderLaunchAction,
            shouldForceTextEntrySubmit: shouldForceTextEntrySubmit
        )
    }

    static func allowsSubmitActionSelection(
        pendingProviderLaunchAction: TextBoxSubmitAction?,
        shouldForceTextEntrySubmit: Bool
    ) -> Bool {
        pendingProviderLaunchAction == nil && !shouldForceTextEntrySubmit
    }

    var isPendingProviderLaunchAwaitingAgent: Bool {
        Self.isPendingProviderLaunchAwaitingAgent(
            pendingProviderLaunchAction: pendingProviderLaunchAction,
            terminalAgentContext: terminalAgentContext
        )
    }

    func startPendingProviderLaunch(_ action: TextBoxSubmitAction) {
        pendingProviderLaunchAction = action
        pendingProviderLaunchStartedAt = Date()
        schedulePendingProviderLaunchTimeout()
    }

    func clearPendingProviderLaunch() {
        pendingProviderLaunchAction = nil
        pendingProviderLaunchStartedAt = nil
        pendingProviderLaunchTimeoutTimer?.invalidate()
        pendingProviderLaunchTimeoutTimer = nil
    }

    func cancelPendingProviderLaunch() {
        guard pendingProviderLaunchAction != nil else { return }
        clearPendingProviderLaunch()
        onClearLaunchCommand()
    }

    func reconcilePendingProviderLaunch() {
        guard pendingProviderLaunchAction != nil else { return }
        let pendingLaunchExpired = Self.isPendingProviderLaunchExpired(startedAt: pendingProviderLaunchStartedAt)
        if Self.shouldClearPendingProviderLaunch(
            shellActivityState: shellActivityState,
            terminalAgentContext: terminalAgentContext,
            pendingLaunchExpired: pendingLaunchExpired
        ) {
            if pendingLaunchExpired ||
                Self.shouldClearLaunchCommandWhenClearingPending(terminalAgentContext: terminalAgentContext) {
                onClearLaunchCommand()
            }
            clearPendingProviderLaunch()
        }
    }

    func schedulePendingProviderLaunchTimeout() {
        pendingProviderLaunchTimeoutTimer?.invalidate()
        let remainingSeconds = Self.pendingProviderLaunchTimeoutDelay(startedAt: pendingProviderLaunchStartedAt)
        pendingProviderLaunchTimeoutTimer = Timer.scheduledTimer(withTimeInterval: remainingSeconds, repeats: false) { _ in
            reconcilePendingProviderLaunch()
        }
    }

    static func shouldClearPendingProviderLaunch(
        shellActivityState: PanelShellActivityState,
        terminalAgentContext: String,
        pendingLaunchExpired: Bool = false
    ) -> Bool {
        if pendingLaunchExpired || TextBoxAgentDetection.supportsActiveAgentPrefixes(context: terminalAgentContext) {
            return true
        }
        if TextBoxAgentDetection.hasPendingTextBoxLaunchContext(terminalAgentContext) {
            return false
        }
        if TextBoxAgentDetection.supportsAgentPrefixes(context: terminalAgentContext) {
            return true
        }
        return shellActivityState == .promptIdle
    }

    static func isPendingProviderLaunchExpired(
        startedAt: Date?,
        now: Date = Date(),
        timeoutSeconds: TimeInterval = Self.pendingProviderLaunchTimeoutSeconds
    ) -> Bool {
        guard let startedAt else { return false }
        return now.timeIntervalSince(startedAt) >= timeoutSeconds
    }

    static func pendingProviderLaunchTimeoutDelay(
        startedAt: Date?,
        now: Date = Date(),
        timeoutSeconds: TimeInterval = Self.pendingProviderLaunchTimeoutSeconds
    ) -> TimeInterval {
        guard let startedAt else { return timeoutSeconds }
        return max(0, timeoutSeconds - now.timeIntervalSince(startedAt))
    }

    static func shouldClearLaunchCommandWhenClearingPending(terminalAgentContext: String) -> Bool {
        !TextBoxAgentDetection.supportsAgentPrefixes(context: terminalAgentContext)
    }

    static func shouldForceTextEntrySubmit(
        allowsCommandTemplateSubmit: Bool,
        terminalAgentContext: String
    ) -> Bool {
        TextBoxAgentDetection.supportsActiveAgentPrefixes(context: terminalAgentContext) ||
            (!allowsCommandTemplateSubmit && TextBoxAgentDetection.supportsAgentPrefixes(context: terminalAgentContext))
    }

    static func allowsCommandTemplateSubmit(shellActivityState: PanelShellActivityState) -> Bool {
        shellActivityState == .promptIdle
    }

    var shouldUseTextEntryFallbackForCommandTemplate: Bool {
        Self.shouldUseTextEntryFallbackForCommandTemplate(
            action: selectedSubmitAction,
            shouldForceTextEntrySubmit: shouldForceTextEntrySubmit,
            allowsCommandTemplateSubmit: allowsCommandTemplateSubmit
        )
    }

    static func shouldUseTextEntryFallbackForCommandTemplate(
        action: TextBoxSubmitAction,
        shouldForceTextEntrySubmit: Bool,
        allowsCommandTemplateSubmit: Bool
    ) -> Bool {
        false
    }

    static func shouldFailClosedForCommandTemplate(
        action: TextBoxSubmitAction,
        shouldForceTextEntrySubmit: Bool,
        allowsCommandTemplateSubmit: Bool
    ) -> Bool {
        guard action.kind == .commandTemplate,
              !shouldForceTextEntrySubmit else {
            return false
        }
        guard allowsCommandTemplateSubmit else { return true }
        if action.command(forPrompt: "") != nil {
            return false
        }
        return providerLaunchCommand(
            for: action,
            shouldForceTextEntrySubmit: shouldForceTextEntrySubmit,
            allowsCommandTemplateSubmit: allowsCommandTemplateSubmit
        ) == nil
    }

    static func shouldEnableSubmitButton(
        baseCanSend: Bool, pendingProviderLaunchAction: TextBoxSubmitAction?, action: TextBoxSubmitAction,
        shouldForceTextEntrySubmit: Bool, allowsCommandTemplateSubmit: Bool
    ) -> Bool {
        baseCanSend && pendingProviderLaunchAction == nil && !shouldFailClosedForCommandTemplate(action: action, shouldForceTextEntrySubmit: shouldForceTextEntrySubmit, allowsCommandTemplateSubmit: allowsCommandTemplateSubmit)
    }

    static func isPendingProviderLaunchAwaitingAgent(
        pendingProviderLaunchAction: TextBoxSubmitAction?,
        terminalAgentContext: String
    ) -> Bool {
        pendingProviderLaunchAction != nil &&
            !TextBoxAgentDetection.supportsActiveAgentPrefixes(context: terminalAgentContext)
    }

    static func textEntryTerminalAgentContext(
        allowsCommandTemplateSubmit: Bool,
        terminalAgentContext: String,
        pendingProviderLaunchAction: TextBoxSubmitAction? = nil
    ) -> String {
        if let activeContext = TextBoxAgentDetection.activeAgentHookContext(from: terminalAgentContext) {
            return activeContext
        }
        if let pendingContext = pendingProviderLaunchAction?.pendingTerminalAgentContext {
            return pendingContext
        }
        return allowsCommandTemplateSubmit ? "" : terminalAgentContext
    }

    var effectiveSubmitAction: TextBoxSubmitAction {
        guard !shouldForceTextEntrySubmit,
              !shouldUseTextEntryFallbackForCommandTemplate else {
            return TextBoxSubmitAction.textEntryAction
        }
        return selectedSubmitAction
    }

    var submitActionPresentation: TextBoxSubmitActionPresentation {
        Self.submitActionPresentation(
            selectedSubmitAction: selectedSubmitAction,
            shouldForceTextEntrySubmit: shouldForceTextEntrySubmit
        )
    }

    static func submitActionPresentation(
        selectedSubmitAction: TextBoxSubmitAction,
        shouldForceTextEntrySubmit: Bool
    ) -> TextBoxSubmitActionPresentation {
        let action = shouldForceTextEntrySubmit ? TextBoxSubmitAction.textEntryAction : selectedSubmitAction
        return TextBoxSubmitActionPresentation(
            action: action,
            isForcedTextEntry: shouldForceTextEntrySubmit
        )
    }

    func sendButton(
        canSend: Bool,
        presentation: TextBoxSubmitActionPresentation
    ) -> some View {
        Button {
            guard canSend else {
                NSSound.beep()
                return
            }
            submit()
        } label: {
            submitButtonActionImage(presentation.action, canSend: canSend)
                .cmuxFont(size: TextBoxLayout.sendSymbolSize, weight: .bold)
                .frame(
                    width: TextBoxSubmitActionImageSupport.iconSize,
                    height: TextBoxSubmitActionImageSupport.iconSize
                )
                .frame(width: TextBoxLayout.iconButtonSize, height: TextBoxLayout.iconButtonSize)
        }
        .buttonStyle(TextBoxSendButtonStyle(
            canSend: canSend
        ))
        .help(presentation.helpText)
        .accessibilityLabel(presentation.accessibilityLabel)
        .frame(width: TextBoxLayout.iconButtonSize, height: TextBoxLayout.iconButtonSize)
        .contextMenu {
            if pendingProviderLaunchAction != nil {
                Button {
                    cancelPendingProviderLaunch()
                } label: {
                    Label(
                        String(localized: "textbox.submitAction.cancelPending", defaultValue: "Cancel Pending Launch"),
                        systemImage: "xmark.circle"
                    )
                }
                Divider()
            }
            if allowsSubmitActionSelection {
                ForEach(submitActions) { action in
                    Button {
                        selectedSubmitActionID = action.id
                    } label: {
                        submitActionMenuLabel(action)
                    }
                }
                Divider()
            }
            Button {
                openSubmitActionsDocumentation()
            } label: {
                Label(
                    String(localized: "textbox.submitAction.docs", defaultValue: "TextBox Submit Actions Docs"),
                    systemImage: "book"
                )
            }
        }
    }

    @ViewBuilder
    func submitButtonActionImage(_ action: TextBoxSubmitAction, canSend: Bool) -> some View {
        let iconOpacity = canSend ? 0.86 : 0.76
        if let image = submitActionNSImage(for: action) {
            Image(nsImage: image)
                .renderingMode(action.id == "codex" ? .template : .original)
                .resizable()
                .scaledToFit()
                .foregroundStyle(Color.black)
                .opacity(iconOpacity)
                .frame(
                    width: TextBoxSubmitActionImageSupport.iconSize,
                    height: TextBoxSubmitActionImageSupport.iconSize
                )
        } else {
            Image(systemName: action.systemImage)
                .foregroundStyle(Color.black)
                .opacity(iconOpacity)
                .frame(
                    width: TextBoxSubmitActionImageSupport.iconSize,
                    height: TextBoxSubmitActionImageSupport.iconSize
                )
        }
    }

    @ViewBuilder
    func submitActionImage(_ action: TextBoxSubmitAction) -> some View {
        if let image = submitActionNSImage(for: action) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(
                    width: TextBoxSubmitActionImageSupport.iconSize,
                    height: TextBoxSubmitActionImageSupport.iconSize
                )
        } else {
            Image(systemName: action.systemImage)
                .frame(
                    width: TextBoxSubmitActionImageSupport.iconSize,
                    height: TextBoxSubmitActionImageSupport.iconSize
                )
        }
    }

    @ViewBuilder
    func submitActionMenuLabel(_ action: TextBoxSubmitAction) -> some View {
        let title = TextBoxSubmitActionPresentation.localizedTitle(for: action)
        if action.id == selectedSubmitAction.id {
            Label(title, systemImage: "checkmark")
        } else {
            Label {
                Text(title)
            } icon: {
                submitActionImage(action)
            }
        }
    }

    func submitActionNSImage(for action: TextBoxSubmitAction) -> NSImage? {
        if let path = action.imagePath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty {
            return submitActionImageCache[submitActionPathImageCacheKey(expandedSubmitActionImagePath(path))]
        }
        if let assetName = action.assetName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !assetName.isEmpty {
            return submitActionImageCache[submitActionAssetImageCacheKey(assetName)]
        }
        return nil
    }

    @MainActor
    func refreshSubmitActionImageCache(keys: [String]) async {
        let keySet = Set(keys)
        submitActionImageCache = submitActionImageCache.filter { keySet.contains($0.key) }

        for key in keys where submitActionImageCache[key] == nil {
            if let path = submitActionPath(fromCacheKey: key) {
                let image = await Task.detached(priority: .utility) {
                    TextBoxSubmitActionImageSupport.image(atPath: path)
                }.value
                guard !Task.isCancelled else { return }
                if let image {
                    submitActionImageCache[key] = image
                }
            } else if let assetName = submitActionAssetName(fromCacheKey: key),
                      let image = NSImage(named: assetName) {
                submitActionImageCache[key] = TextBoxSubmitActionImageSupport.fixedSizeImage(image)
            }
        }
    }

    func expandedSubmitActionImagePath(_ path: String) -> String {
        NSString(string: path).expandingTildeInPath
    }

    func submitActionPathImageCacheKey(_ path: String) -> String {
        "path:\(path)"
    }

    func submitActionAssetImageCacheKey(_ assetName: String) -> String {
        "asset:\(assetName)"
    }

    func submitActionPath(fromCacheKey key: String) -> String? {
        guard key.hasPrefix("path:") else { return nil }
        return String(key.dropFirst("path:".count))
    }

    func submitActionAssetName(fromCacheKey key: String) -> String? {
        guard key.hasPrefix("asset:") else { return nil }
        return String(key.dropFirst("asset:".count))
    }

    struct SubmitDispatchPlan {
        let events: [TextBoxSubmit.DispatchEvent]
        let cleanupTerminalAgentContext: String
        let launchCommand: String?
        let launchContextCommand: String?
    }

    func dispatchPlan(
        _ parts: [TextBoxSubmissionPart],
        applying action: TextBoxSubmitAction
    ) -> SubmitDispatchPlan {
        Self.dispatchPlan(
            parts,
            applying: action,
            shouldForceTextEntrySubmit: shouldForceTextEntrySubmit,
            allowsCommandTemplateSubmit: allowsCommandTemplateSubmit,
            terminalAgentContext: terminalAgentContext,
            pendingProviderLaunchAction: pendingProviderLaunchAction
        )
    }

    static func dispatchPlan(
        _ parts: [TextBoxSubmissionPart],
        applying action: TextBoxSubmitAction,
        shouldForceTextEntrySubmit: Bool,
        allowsCommandTemplateSubmit: Bool,
        terminalAgentContext: String,
        pendingProviderLaunchAction: TextBoxSubmitAction?
    ) -> SubmitDispatchPlan {
        guard !shouldForceTextEntrySubmit, allowsCommandTemplateSubmit else {
            let textEntryContext = Self.textEntryTerminalAgentContext(
                allowsCommandTemplateSubmit: allowsCommandTemplateSubmit,
                terminalAgentContext: terminalAgentContext,
                pendingProviderLaunchAction: pendingProviderLaunchAction
            )
            return SubmitDispatchPlan(
                events: TextBoxSubmit.dispatchEvents(for: parts, terminalAgentContext: textEntryContext),
                cleanupTerminalAgentContext: textEntryContext,
                launchCommand: nil,
                launchContextCommand: nil
            )
        }

        guard let command = action.command(forPrompt: TextBoxSubmissionFormatter.formattedText(from: parts)) else {
            let textEntryContext = Self.textEntryTerminalAgentContext(
                allowsCommandTemplateSubmit: allowsCommandTemplateSubmit,
                terminalAgentContext: terminalAgentContext,
                pendingProviderLaunchAction: pendingProviderLaunchAction
            )
            return SubmitDispatchPlan(
                events: TextBoxSubmit.dispatchEvents(for: parts, terminalAgentContext: textEntryContext),
                cleanupTerminalAgentContext: textEntryContext,
                launchCommand: nil,
                launchContextCommand: nil
            )
        }
        return SubmitDispatchPlan(
            events: TextBoxSubmit.dispatchEvents(for: [.text(command)], terminalAgentContext: ""),
            cleanupTerminalAgentContext: Self.textEntryTerminalAgentContext(
                allowsCommandTemplateSubmit: allowsCommandTemplateSubmit,
                terminalAgentContext: terminalAgentContext,
                pendingProviderLaunchAction: pendingProviderLaunchAction
            ),
            launchCommand: command,
            launchContextCommand: Self.recordableLaunchContextCommand(for: action)
        )
    }

    static func recordableLaunchContextCommand(for action: TextBoxSubmitAction) -> String? {
        guard let launchContextCommand = action.launchContextCommand(),
              TextBoxAgentDetection.boundedLaunchCommandContext(from: launchContextCommand) != nil else {
            return nil
        }
        return launchContextCommand
    }

    func providerLaunchCommand(for action: TextBoxSubmitAction) -> String? {
        Self.providerLaunchCommand(
            for: action,
            shouldForceTextEntrySubmit: shouldForceTextEntrySubmit,
            allowsCommandTemplateSubmit: allowsCommandTemplateSubmit
        )
    }

    static func providerLaunchCommand(
        for action: TextBoxSubmitAction,
        shouldForceTextEntrySubmit: Bool,
        allowsCommandTemplateSubmit: Bool
    ) -> String? {
        guard !shouldForceTextEntrySubmit,
              allowsCommandTemplateSubmit,
              let command = action.launchCommand(),
              Self.recordableLaunchContextCommand(for: action) != nil else {
            return nil
        }
        return command
    }

    func cycleSubmitAction() {
        surface.owningWorkspace()?.clearStaleAgentPIDs()
        guard Self.allowsSubmitActionSelection(
            pendingProviderLaunchAction: pendingProviderLaunchAction,
            shouldForceTextEntrySubmit: shouldForceTextEntrySubmit
        ) else {
            return
        }
        guard let nextID = Self.nextCycledSubmitActionID(
            defaultSubmitActionID: effectiveSubmitActionID,
            submitActions: submitActions,
            shouldForceTextEntrySubmit: shouldForceTextEntrySubmit
        ) else {
            return
        }
        selectedSubmitActionID = nextID
    }

    static func panelSubmitActionIDAfterSuccessfulSubmit(
        currentSubmitActionID: String,
        submittedAction: TextBoxSubmitAction
    ) -> String {
        guard submittedAction.kind == .commandTemplate else { return currentSubmitActionID }
        return TextBoxSubmitAction.textEntryAction.id
    }

    static func nextCycledSubmitActionID(
        defaultSubmitActionID: String,
        submitActions: [TextBoxSubmitAction],
        shouldForceTextEntrySubmit: Bool
    ) -> String? {
        guard !shouldForceTextEntrySubmit, !submitActions.isEmpty else { return nil }
        let currentIndex = submitActions.firstIndex(where: { $0.id == defaultSubmitActionID }) ?? 0
        let nextIndex = submitActions.index(after: currentIndex)
        return submitActions[nextIndex == submitActions.endIndex ? submitActions.startIndex : nextIndex].id
    }

    func openSubmitActionsDocumentation() {
        guard let url = URL(string: "https://github.com/manaflow-ai/cmux/blob/main/docs/configuration.md#terminaltextboxsubmitactions") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
