import CmuxMobileShell
import CmuxMobileSupport
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Full-screen prompt composer: describe a task, pick where it runs and which
/// agent runs it, then launch. On success the shell has already selected the
/// new workspace, so dismissing this cover reveals the agent's live terminal.
struct AgentLaunchComposerView: View {
    /// Owned by the presenting list so a swiped-away composer keeps its draft.
    @Binding var draft: String
    let fetchOptions: () async -> MobileAgentLaunchOptions?
    let launch: (
        _ prompt: String,
        _ agentID: String?,
        _ directoryPath: String?
    ) async -> Result<Void, MobileWorkspaceMutationFailure>

    @Environment(\.dismiss) private var dismiss
    @FocusState private var isPromptFocused: Bool
    @State private var options: MobileAgentLaunchOptions?
    @State private var selectedAgentID: String?
    @State private var selectedDirectoryPath: String?
    @State private var isLaunching = false
    @State private var launchFailure: MobileWorkspaceMutationFailure?

    /// Offered while `mobile.agent.launch_options` is still in flight (or the
    /// Mac never answers); the Mac re-validates the agent at launch.
    private static let fallbackAgents = [
        MobileAgentLaunchOptions.Agent(id: "claude", name: "Claude Code", installed: true),
        MobileAgentLaunchOptions.Agent(id: "codex", name: "Codex", installed: true),
    ]

    var body: some View {
        NavigationStack {
            promptEditor
                .safeAreaInset(edge: .bottom) { accessoryBar }
                .navigationTitle(L10n.string("mobile.agentLaunch.title", defaultValue: "New Agent Task"))
                .mobileInlineNavigationTitle()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.string("mobile.common.cancel", defaultValue: "Cancel")) {
                            dismiss()
                        }
                        .accessibilityIdentifier("MobileAgentLaunchCancel")
                    }
                }
        }
        .task {
            if options == nil {
                options = await fetchOptions()
            }
        }
        .accessibilityIdentifier("MobileAgentLaunchComposer")
    }

    // MARK: - Prompt editor

    private var promptEditor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $draft)
                .focused($isPromptFocused)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .accessibilityIdentifier("MobileAgentLaunchPrompt")
            if draft.isEmpty {
                Text(
                    L10n.string(
                        "mobile.agentLaunch.prompt.placeholder",
                        defaultValue: "Describe a task for the agent…"
                    )
                )
                .font(.body)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 17)
                .padding(.top, 16)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .onAppear { isPromptFocused = true }
    }

    // MARK: - Accessory bar

    @ViewBuilder
    private var accessoryBar: some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            GlassEffectContainer { accessoryBarContent }
        } else {
            accessoryBarContent
        }
        #else
        accessoryBarContent
        #endif
    }

    private var accessoryBarContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let launchFailure {
                Text(
                    String.localizedStringWithFormat(
                        L10n.string(
                            "mobile.agentLaunch.failure.message",
                            defaultValue: "Couldn't launch: %@."
                        ),
                        launchFailure.reasonText
                    )
                )
                .font(.footnote)
                .foregroundStyle(.red)
                .padding(.horizontal, 4)
                .accessibilityIdentifier("MobileAgentLaunchError")
            }
            HStack(spacing: 8) {
                directoryChip
                agentChip
                Spacer(minLength: 8)
                launchButton
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 2)
        .padding(.bottom, 8)
    }

    private var directoryChip: some View {
        Menu {
            Button {
                selectedDirectoryPath = nil
            } label: {
                if selectedDirectoryPath == nil {
                    Label(autoDirectoryTitle, systemImage: "checkmark")
                } else {
                    Text(autoDirectoryTitle)
                }
            }
            ForEach(options?.directoryPaths ?? [], id: \.self) { path in
                Button {
                    selectedDirectoryPath = path
                } label: {
                    if selectedDirectoryPath == path {
                        Label(path, systemImage: "checkmark")
                    } else {
                        Text(path)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "folder")
                    .font(.footnote)
                Text(directoryChipTitle)
                    .font(.subheadline)
                    .lineLimit(1)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .frame(height: 40)
        }
        .mobileGlassPill()
        .accessibilityLabel(L10n.string("mobile.agentLaunch.directory.a11y", defaultValue: "Working directory"))
        .accessibilityIdentifier("MobileAgentLaunchDirectory")
    }

    private var agentChip: some View {
        Menu {
            ForEach(resolvedAgents) { agent in
                Button {
                    selectedAgentID = agent.id
                } label: {
                    if agent.id == resolvedAgentID {
                        Label(agentMenuTitle(agent), systemImage: "checkmark")
                    } else {
                        Text(agentMenuTitle(agent))
                    }
                }
                .disabled(!agent.installed)
            }
        } label: {
            HStack(spacing: 5) {
                Text(resolvedAgentName)
                    .font(.subheadline)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .frame(height: 40)
        }
        .mobileGlassPill()
        .accessibilityLabel(L10n.string("mobile.agentLaunch.agent.a11y", defaultValue: "Agent"))
        .accessibilityIdentifier("MobileAgentLaunchAgent")
    }

    private var launchButton: some View {
        Button(action: performLaunch) {
            HStack(spacing: 6) {
                if isLaunching {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                }
                Text(L10n.string("mobile.agentLaunch.launch", defaultValue: "Launch"))
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
            }
            // The action label must never wrap; the chips truncate instead.
            .fixedSize(horizontal: true, vertical: false)
        }
        .mobileGlassProminentButton()
        .disabled(!canLaunch)
        .accessibilityIdentifier("MobileAgentLaunchButton")
    }

    // MARK: - Selection resolution

    private var resolvedAgents: [MobileAgentLaunchOptions.Agent] {
        let agents = options?.agents ?? []
        return agents.isEmpty ? Self.fallbackAgents : agents
    }

    private var resolvedAgentID: String? {
        if let selectedAgentID,
           resolvedAgents.contains(where: { $0.id == selectedAgentID && $0.installed }) {
            return selectedAgentID
        }
        return resolvedAgents.first(where: \.installed)?.id ?? resolvedAgents.first?.id
    }

    private var resolvedAgentName: String {
        resolvedAgents.first(where: { $0.id == resolvedAgentID })?.name
            ?? Self.fallbackAgents[0].name
    }

    private func agentMenuTitle(_ agent: MobileAgentLaunchOptions.Agent) -> String {
        guard !agent.installed else { return agent.name }
        return String.localizedStringWithFormat(
            L10n.string(
                "mobile.agentLaunch.agent.notInstalledFormat",
                defaultValue: "%@ (not installed)"
            ),
            agent.name
        )
    }

    private var autoDirectoryTitle: String {
        if let defaultDirectory = options?.defaultDirectory,
           let basename = Self.pathBasename(defaultDirectory) {
            return String.localizedStringWithFormat(
                L10n.string(
                    "mobile.agentLaunch.directory.autoFormat",
                    defaultValue: "Auto (%@)"
                ),
                basename
            )
        }
        return L10n.string("mobile.agentLaunch.directory.auto", defaultValue: "Auto")
    }

    private var directoryChipTitle: String {
        if let selectedDirectoryPath,
           let basename = Self.pathBasename(selectedDirectoryPath) {
            return basename
        }
        if let defaultDirectory = options?.defaultDirectory,
           let basename = Self.pathBasename(defaultDirectory) {
            return basename
        }
        return L10n.string("mobile.agentLaunch.directory.auto", defaultValue: "Auto")
    }

    private static func pathBasename(_ path: String) -> String? {
        // A macOS home directory reads better as "~" than as the username.
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        if components.count == 2, components[0] == "Users" {
            return "~"
        }
        let basename = (path as NSString).lastPathComponent
        return basename.isEmpty ? nil : basename
    }

    // MARK: - Launch

    private var trimmedPrompt: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canLaunch: Bool {
        !trimmedPrompt.isEmpty && !isLaunching
    }

    private func performLaunch() {
        guard canLaunch else { return }
        let prompt = trimmedPrompt
        let agentID = resolvedAgentID
        let directoryPath = selectedDirectoryPath
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        #endif
        isLaunching = true
        launchFailure = nil
        Task { @MainActor in
            let result = await launch(prompt, agentID, directoryPath)
            isLaunching = false
            switch result {
            case .success:
                #if os(iOS)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                #endif
                draft = ""
                dismiss()
            case let .failure(failure):
                #if os(iOS)
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                #endif
                launchFailure = failure
            }
        }
    }
}
