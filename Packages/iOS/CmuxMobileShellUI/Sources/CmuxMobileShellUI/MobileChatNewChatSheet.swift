import CmuxMobileShell
import CmuxMobileShellModel
import SwiftUI

/// Provider picker and prompt sheet for creating a new native chat.
struct MobileChatNewChatSheet: View {
    @Bindable var store: CMUXMobileShellStore
    let onChooseComputer: () -> Void
    let onStarted: (MobileChatProvider, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var promptFocused: Bool
    @State private var selectedProvider: MobileChatProvider = .codex
    @State private var prompt = ""
    @State private var isStarting = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    MobileChatNewChatIntro()
                    MobileChatProviderPicker(selection: $selectedProvider)
                    MobileChatPromptEditor(text: $prompt, isFocused: $promptFocused)
                    MobileChatComputerSummary(
                        name: store.connectedHostName,
                        isConnected: store.hasAnyConnectedMac,
                        onChoose: {
                            dismiss()
                            onChooseComputer()
                        }
                    )
                    if let errorMessage {
                        MobileChatInlineError(message: errorMessage)
                    }
                    Button {
                        Task { await startChat() }
                    } label: {
                        HStack {
                            if isStarting { ProgressView().tint(.white) }
                            Text(isStarting ? "Starting…" : "Start \(selectedProvider.title) chat")
                                .fontWeight(.semibold)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(
                        isStarting
                            || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || targetComputer == nil
                    )
                    .accessibilityIdentifier("MobileChatStart")
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("New chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel", action: { dismiss() })
                        .accessibilityIdentifier("MobileChatCancel")
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private func startChat() async {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return }
        guard let target = targetComputer else {
            errorMessage = "Connect a computer before starting a chat."
            return
        }
        isStarting = true
        errorMessage = nil
        let template = store.taskTemplateStore?.listTemplates().first {
            $0.builtInKind == selectedProvider.builtInTemplateKind
        } ?? selectedProvider.defaultTemplate
        let composition = MobileTaskCommandComposer().compose(
            template: template,
            prompt: trimmedPrompt
        )
        let spec = MobileWorkspaceCreateSpec(
            title: composition.title,
            initialCommand: composition.initialCommand,
            initialEnv: composition.initialEnv,
            operationID: UUID()
        )
        let result = await store.submitTaskComposer(
            macDeviceID: target.macDeviceID,
            instanceTag: target.instanceTag,
            spec: spec
        )
        isStarting = false
        switch result {
        case .success:
            onStarted(selectedProvider, trimmedPrompt)
            dismiss()
        case .failure:
            errorMessage = "The chat could not be started on this computer."
        }
    }

    private var targetComputer: MobileChatTarget? {
        if let connectedID = store.connectedMacDeviceID {
            if let saved = store.displayPairedMacs.first(where: {
                $0.macDeviceID == connectedID
            }) {
                return MobileChatTarget(
                    macDeviceID: saved.macDeviceID,
                    instanceTag: saved.instanceTag
                )
            }
            return MobileChatTarget(
                macDeviceID: connectedID,
                instanceTag: store.connectedMacInstanceTag
            )
        }
        return nil
    }
}

private struct MobileChatTarget {
    let macDeviceID: String
    let instanceTag: String?
}

private struct MobileChatNewChatIntro: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("What are you working on?")
                .font(.title2.weight(.bold))
            Text("Choose an agent, describe the task, and cmux will open a focused workspace for it.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

private struct MobileChatProviderPicker: View {
    @Binding var selection: MobileChatProvider

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Agent")
                .font(.subheadline.weight(.semibold))
            ForEach(MobileChatProvider.allCases) { provider in
                Button {
                    selection = provider
                } label: {
                    HStack(spacing: 13) {
                        MobileChatProviderBadge(provider: provider, size: 42)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(provider.title)
                                .font(.body.weight(.semibold))
                            Text(provider.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: selection == provider ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(selection == provider ? provider.tint : Color.secondary)
                    }
                    .padding(12)
                    .contentShape(Rectangle())
                    .background(selection == provider ? provider.tint.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(selection == provider ? provider.tint.opacity(0.35) : Color.secondary.opacity(0.18), lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(provider.title)
                .accessibilityValue(selection == provider ? "Selected" : "")
                .accessibilityIdentifier("MobileChatProvider-\(provider.title)")
            }
        }
    }
}

private struct MobileChatPromptEditor: View {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Prompt")
                .font(.subheadline.weight(.semibold))
            HStack(alignment: .bottom, spacing: 8) {
                Button(action: {}) {
                    Image(systemName: "plus")
                        .foregroundStyle(.secondary)
                }
                .disabled(true)
                .accessibilityLabel("Add attachment")
                TextField("Describe the task…", text: $text, axis: .vertical)
                    .lineLimit(4...8)
                    .focused(isFocused)
                    .accessibilityIdentifier("MobileChatPrompt")
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title3)
                    .foregroundStyle(
                        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? Color.secondary.opacity(0.45)
                            : Color.accentColor
                    )
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.separator.opacity(0.65), lineWidth: 0.7))
        }
    }
}

private struct MobileChatComputerSummary: View {
    let name: String
    let isConnected: Bool
    let onChoose: () -> Void

    var body: some View {
        Button(action: onChoose) {
            HStack(spacing: 12) {
                Image(systemName: "desktopcomputer")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, height: 34)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Computer")
                        .font(.subheadline.weight(.semibold))
                    Text(isConnected ? (name.isEmpty ? "Connected" : name) : "No computer connected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Circle()
                    .fill(isConnected ? .green : .secondary)
                    .frame(width: 7, height: 7)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("MobileChatComputerSummary")
    }
}
