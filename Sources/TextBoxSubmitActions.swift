import AppKit
import SwiftUI

struct TextBoxSubmitActionPresentation: Equatable {
    let action: TextBoxSubmitAction
    let isForcedTextEntry: Bool

    var label: String {
        if isForcedTextEntry {
            return String(localized: "textbox.submitAction.activeAgent", defaultValue: "Text Entry for Active Agent")
        }
        return Self.localizedTitle(for: action)
    }

    var accessibilityLabel: String {
        String(
            format: String(localized: "textbox.submitAction.accessibility", defaultValue: "Submit with %@"),
            label
        )
    }

    var helpText: String {
        if isForcedTextEntry {
            return String(localized: "textbox.submitAction.activeAgent.tooltip", defaultValue: "Active agent sessions use Text Entry. Shift-Tab changes the default for new sessions.")
        }
        return String(
            format: String(localized: "textbox.submitAction.tooltip", defaultValue: "Submit with %@. Press Shift-Tab to change."),
            label
        )
    }

    var backgroundColor: Color {
        Color(hex: action.backgroundColorHex.trimmingCharacters(in: .whitespacesAndNewlines)) ?? .white
    }

    static func localizedTitle(for action: TextBoxSubmitAction) -> String {
        switch action.id {
        case TextBoxSubmitAction.textEntryAction.id:
            return String(localized: "textbox.submitAction.textEntry", defaultValue: "Text Entry")
        case "claude":
            return String(localized: "textbox.submitAction.claude", defaultValue: "Claude")
        case "codex":
            return String(localized: "textbox.submitAction.codex", defaultValue: "Codex")
        case "opencode":
            return String(localized: "textbox.submitAction.opencode", defaultValue: "OpenCode")
        case "pi":
            return String(localized: "textbox.submitAction.pi", defaultValue: "Pi")
        default:
            return action.title
        }
    }
}

private enum TextBoxSubmitActionImageLoader {
    static let maximumImageBytes = 2 * 1024 * 1024

    static func imageData(atPath path: String) -> Data? {
        let url = URL(fileURLWithPath: path, isDirectory: false)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let fileSize = values.fileSize,
              fileSize > 0,
              fileSize <= maximumImageBytes else {
            return nil
        }
        return try? Data(contentsOf: url, options: [.mappedIfSafe])
    }
}

private enum TextBoxSubmitActionIconMetrics {
    static let size: CGFloat = 16
}

extension TextBoxInputContainer {
    var submitActions: [TextBoxSubmitAction] {
        submitActionsCache
    }

    var submitActionImagePaths: [String] {
        let paths = submitActions.compactMap { action -> String? in
            guard let path = action.imagePath?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !path.isEmpty else {
                return nil
            }
            return expandedSubmitActionImagePath(path)
        }
        return Array(Set(paths)).sorted()
    }

    var submitActionImagePathCacheKey: String {
        submitActionImagePaths.joined(separator: "\u{1F}")
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
        hasPendingProviderLaunch || Self.shouldForceTextEntrySubmit(
            allowsCommandTemplateSubmit: allowsCommandTemplateSubmit,
            terminalAgentContext: terminalAgentContext
        )
    }

    static func shouldForceTextEntrySubmit(
        allowsCommandTemplateSubmit: Bool,
        terminalAgentContext _: String
    ) -> Bool {
        !allowsCommandTemplateSubmit
    }

    static func textEntryTerminalAgentContext(
        allowsCommandTemplateSubmit: Bool,
        terminalAgentContext: String
    ) -> String {
        allowsCommandTemplateSubmit ? "" : terminalAgentContext
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
                    width: TextBoxSubmitActionIconMetrics.size,
                    height: TextBoxSubmitActionIconMetrics.size
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
        if let path = action.imagePath,
           let image = submitActionImageCache[expandedSubmitActionImagePath(path)] {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(
                    width: TextBoxSubmitActionIconMetrics.size,
                    height: TextBoxSubmitActionIconMetrics.size
                )
        } else if let assetName = action.assetName {
            Image(assetName)
                .resizable()
                .scaledToFit()
                .frame(
                    width: TextBoxSubmitActionIconMetrics.size,
                    height: TextBoxSubmitActionIconMetrics.size
                )
        } else {
            Image(systemName: action.systemImage)
                .frame(
                    width: TextBoxSubmitActionIconMetrics.size,
                    height: TextBoxSubmitActionIconMetrics.size
                )
        }
    }

    @ViewBuilder
    func submitActionMenuLabel(_ action: TextBoxSubmitAction) -> some View {
        let title = TextBoxSubmitActionPresentation.localizedTitle(for: action)
        if action.id == selectedSubmitAction.id {
            Label(title, systemImage: "checkmark")
        } else if let assetName = action.assetName {
            Label(title, image: assetName)
        } else {
            Label(title, systemImage: action.systemImage)
        }
    }

    @MainActor
    func refreshSubmitActionImageCache(paths: [String]) async {
        let pathSet = Set(paths)
        submitActionImageCache = submitActionImageCache.filter { pathSet.contains($0.key) }

        for path in paths where submitActionImageCache[path] == nil {
            let data = await Task.detached(priority: .utility) {
                TextBoxSubmitActionImageLoader.imageData(atPath: path)
            }.value
            guard !Task.isCancelled else { return }
            if let data,
               let image = NSImage(data: data) {
                submitActionImageCache[path] = image
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
                terminalAgentContext: terminalAgentContext
            )
            return SubmitDispatchPlan(
                events: TextBoxSubmit.dispatchEvents(for: parts, terminalAgentContext: textEntryContext),
                cleanupTerminalAgentContext: textEntryContext
            )
        }

        guard let command = action.command(forPrompt: TextBoxSubmissionFormatter.formattedText(from: parts)) else {
            let textEntryContext = Self.textEntryTerminalAgentContext(
                allowsCommandTemplateSubmit: allowsCommandTemplateSubmit,
                terminalAgentContext: terminalAgentContext
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
                terminalAgentContext: terminalAgentContext
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
