import AppKit
import SwiftUI

extension TextBoxInputContainer {
    var submitActions: [TextBoxSubmitAction] {
        submitActionsCache
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
            && allowsCommandTemplateSubmit
            && !TextBoxAgentDetection.supportsAgentPrefixes(context: terminalAgentContext)
    }

    func startPendingProviderLaunch(_ action: TextBoxSubmitAction) {
        pendingProviderLaunchAction = action
    }

    func clearPendingProviderLaunch() {
        pendingProviderLaunchAction = nil
    }

    func clearPendingProviderLaunchIfPromptIdleWithoutAgentContext() {
        guard allowsCommandTemplateSubmit,
              !TextBoxAgentDetection.supportsAgentPrefixes(context: terminalAgentContext) else {
            return
        }
        clearPendingProviderLaunch()
    }

    static func shouldForceTextEntrySubmit(
        allowsCommandTemplateSubmit: Bool,
        terminalAgentContext _: String
    ) -> Bool {
        !allowsCommandTemplateSubmit
    }

    static func textEntryTerminalAgentContext(
        allowsCommandTemplateSubmit: Bool,
        terminalAgentContext: String,
        pendingProviderLaunchAction: TextBoxSubmitAction? = nil
    ) -> String {
        if let pendingContext = pendingProviderLaunchAction?.pendingTerminalAgentContext {
            return pendingContext
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
        TextBoxSubmitActionPresentation(
            action: effectiveSubmitAction,
            isForcedTextEntry: shouldForceTextEntrySubmit && selectedSubmitAction.kind != .textEntry
        )
    }

    func sendButton(
        canSend: Bool,
        foreground: Color,
        presentation: TextBoxSubmitActionPresentation
    ) -> some View {
        Button {
            guard canSend else {
                NSSound.beep()
                return
            }
            submit()
        } label: {
            submitActionImage(presentation.action)
                .cmuxFont(size: TextBoxLayout.sendSymbolSize, weight: .bold)
                .frame(
                    width: TextBoxSubmitActionImageSupport.iconSize,
                    height: TextBoxSubmitActionImageSupport.iconSize
                )
                .frame(width: TextBoxLayout.iconButtonSize, height: TextBoxLayout.iconButtonSize)
        }
        .buttonStyle(TextBoxSendButtonStyle(
            canSend: canSend,
            backgroundColor: presentation.backgroundColor
        ))
        .foregroundStyle(canSend ? Color.black.opacity(0.86) : foreground.opacity(0.38))
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

    @MainActor
    func refreshSubmitActionsCache(raw: String) async {
        let actions = await Task.detached(priority: .utility) {
            TerminalTextBoxInputSettings.submitActions(configuredJSON: raw)
        }.value
        guard !Task.isCancelled else { return }
        submitActionsCache = actions
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
    }

    func dispatchPlan(
        _ parts: [TextBoxSubmissionPart],
        applying action: TextBoxSubmitAction
    ) -> SubmitDispatchPlan {
        guard !shouldForceTextEntrySubmit else {
            let textEntryContext = Self.textEntryTerminalAgentContext(
                allowsCommandTemplateSubmit: allowsCommandTemplateSubmit,
                terminalAgentContext: terminalAgentContext,
                pendingProviderLaunchAction: pendingProviderLaunchAction
            )
            return SubmitDispatchPlan(
                events: TextBoxSubmit.dispatchEvents(for: parts, terminalAgentContext: textEntryContext),
                cleanupTerminalAgentContext: textEntryContext
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
                cleanupTerminalAgentContext: textEntryContext
            )
        }
        return SubmitDispatchPlan(
            events: TextBoxSubmit.dispatchEvents(for: [.text(command)], terminalAgentContext: ""),
            cleanupTerminalAgentContext: Self.textEntryTerminalAgentContext(
                allowsCommandTemplateSubmit: allowsCommandTemplateSubmit,
                terminalAgentContext: terminalAgentContext,
                pendingProviderLaunchAction: pendingProviderLaunchAction
            )
        )
    }

    func providerLaunchCommand(for action: TextBoxSubmitAction) -> String? {
        guard !shouldForceTextEntrySubmit else { return nil }
        return action.launchCommand()
    }

    func cycleSubmitAction() {
        let actions = submitActions
        guard !actions.isEmpty else { return }
        let currentIndex = actions.firstIndex(where: { $0.id == defaultSubmitActionID }) ?? 0
        let nextIndex = actions.index(after: currentIndex)
        defaultSubmitActionID = actions[nextIndex == actions.endIndex ? actions.startIndex : nextIndex].id
    }

    func openSubmitActionsDocumentation() {
        guard let url = URL(string: "https://github.com/manaflow-ai/cmux/blob/main/docs/configuration.md#terminaltextboxsubmitactions") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
