import AppKit
import CmuxWorkspaces
import SwiftUI

extension TextBoxInputContainer {
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
        let keys = submitActions.compactMap { action -> String? in
            guard let path = action.imagePath?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !path.isEmpty else {
                if let assetName = action.assetName?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !assetName.isEmpty {
                    return submitActionAssetImageCacheKey(assetName)
                }
                return nil
            }
            return submitActionPathImageCacheKey(expandedSubmitActionImagePath(path))
        }
        return Array(Set(keys)).sorted()
    }

    var submitActionImageCacheTaskKey: String {
        submitActionImageCacheKeys.joined(separator: "\u{1F}")
    }

    var selectedSubmitAction: TextBoxSubmitAction {
        Self.selectedSubmitAction(
            defaultSubmitActionID: defaultSubmitActionID,
            submitActions: submitActions
        )
    }

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
        pendingProviderLaunchAction != nil || Self.shouldForceTextEntrySubmit(
            allowsCommandTemplateSubmit: allowsCommandTemplateSubmit,
            terminalAgentContext: terminalAgentContext
        )
    }

    var isProviderLaunchAwaitingAgentOrCommand: Bool {
        pendingProviderLaunchAction != nil
    }

    func startPendingProviderLaunch(_ action: TextBoxSubmitAction) {
        pendingProviderLaunchAction = action
    }

    func clearPendingProviderLaunch() {
        pendingProviderLaunchAction = nil
    }

    func reconcilePendingProviderLaunch() {
        guard pendingProviderLaunchAction != nil else { return }
        if Self.shouldClearPendingProviderLaunch(
            allowsCommandTemplateSubmit: allowsCommandTemplateSubmit,
            terminalAgentContext: terminalAgentContext
        ) {
            clearPendingProviderLaunch()
        }
    }

    static func shouldClearPendingProviderLaunch(
        allowsCommandTemplateSubmit: Bool,
        terminalAgentContext: String
    ) -> Bool {
        allowsCommandTemplateSubmit || TextBoxAgentDetection.supportsAgentPrefixes(context: terminalAgentContext)
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

    static func shouldAwaitCommandTemplateReadiness(
        action: TextBoxSubmitAction,
        shouldForceTextEntrySubmit: Bool,
        allowsCommandTemplateSubmit: Bool
    ) -> Bool {
        !shouldForceTextEntrySubmit &&
            !allowsCommandTemplateSubmit &&
            action.kind == .commandTemplate
    }

    static func textEntryTerminalAgentContext(
        allowsCommandTemplateSubmit: Bool,
        terminalAgentContext: String,
        pendingProviderLaunchAction: TextBoxSubmitAction? = nil
    ) -> String {
        if let pendingContext = pendingProviderLaunchAction?.pendingTerminalAgentContext {
            return pendingContext
        }
        if TextBoxAgentDetection.supportsActiveAgentPrefixes(context: terminalAgentContext) {
            return terminalAgentContext
        }
        return allowsCommandTemplateSubmit ? "" : terminalAgentContext
    }

    var effectiveSubmitAction: TextBoxSubmitAction {
        guard !shouldForceTextEntrySubmit else {
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
                    clearPendingProviderLaunch()
                } label: {
                    Label(
                        String(localized: "textbox.submitAction.cancelPending", defaultValue: "Cancel Pending Launch"),
                        systemImage: "xmark.circle"
                    )
                }
                Divider()
            }
            ForEach(submitActions) { action in
                Button {
                    defaultSubmitActionID = action.id
                } label: {
                    submitActionMenuLabel(action)
                }
            }
            Divider()
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
                let data = await Task.detached(priority: .utility) {
                    TextBoxSubmitActionImageSupport.imageData(atPath: path)
                }.value
                guard !Task.isCancelled else { return }
                if let data,
                   let image = NSImage(data: data) {
                    submitActionImageCache[key] = TextBoxSubmitActionImageSupport.fixedSizeImage(image)
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
                launchCommand: nil
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
                launchCommand: nil
            )
        }
        return SubmitDispatchPlan(
            events: TextBoxSubmit.dispatchEvents(for: [.text(command)], terminalAgentContext: ""),
            cleanupTerminalAgentContext: Self.textEntryTerminalAgentContext(
                allowsCommandTemplateSubmit: allowsCommandTemplateSubmit,
                terminalAgentContext: terminalAgentContext,
                pendingProviderLaunchAction: pendingProviderLaunchAction
            ),
            launchCommand: command
        )
    }

    func providerLaunchCommand(for action: TextBoxSubmitAction) -> String? {
        guard !shouldForceTextEntrySubmit, allowsCommandTemplateSubmit else { return nil }
        return action.launchCommand()
    }

    func cycleSubmitAction() {
        guard let nextID = Self.nextCycledSubmitActionID(
            defaultSubmitActionID: defaultSubmitActionID,
            submitActions: submitActions,
            shouldForceTextEntrySubmit: shouldForceTextEntrySubmit
        ) else {
            return
        }
        defaultSubmitActionID = nextID
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
