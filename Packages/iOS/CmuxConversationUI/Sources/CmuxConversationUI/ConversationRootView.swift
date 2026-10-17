#if os(iOS)
import CmuxConversation
import SwiftUI

/// The native conversation feature entry point. Inject the host-backed model
/// from the shell bridge; this view never creates a transport or provider SDK.
public struct ConversationRootView: View {
    @State private var model: ConversationModel
    private let embedsNavigationStack: Bool
    @State private var showsNewTask = false

    /// Creates the conversation flow over an injected model.
    public init(model: ConversationModel, embedsNavigationStack: Bool = true) {
        _model = State(initialValue: model)
        self.embedsNavigationStack = embedsNavigationStack
    }

    public var body: some View {
        Group {
            if embedsNavigationStack {
                NavigationStack { content }
            } else {
                content
            }
        }
        .sheet(isPresented: $showsNewTask) {
            ConversationNewTaskSheet(model: model)
        }
        .task {
            model.refreshSessions()
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.selectedSessionID == nil {
            ConversationTaskListView(
                model: model,
                onNewTask: { showsNewTask = true }
            )
        } else {
            ConversationDetailView(model: model)
        }
    }
}

#if DEBUG
/// A compact task list/detail flow useful for previews and iPad split layouts.
public struct ConversationPreviewView: View {
    public init() {}

    public var body: some View {
        ConversationRootView(model: ConversationModel(client: ConversationFixtureClient(), scopeID: "fixture", workspaces: [
            ConversationWorkspaceChoice(id: "fixture", title: "Demo workspace", directory: "/tmp/cmux-fixture")
        ]))
    }
}

#endif

private struct ConversationDetailView: View {
    @Bindable var model: ConversationModel
    @State private var showsFiles = false
    @State private var showsModelSettings = false
    @State private var showsMore = false

    var body: some View {
        VStack(spacing: 0) {
            ConversationHeaderView(
                model: model,
                showsFiles: $showsFiles,
                showsModelSettings: $showsModelSettings,
                showsMore: $showsMore
            )
            ConversationTranscriptView(model: model)
            if let receipt = model.lastReceipt, receipt.state == .accepted || receipt.state == .applied {
                ConversationNoticeView(
                    text: receipt.state == .accepted
                        ? ConversationL10n.value("conversation.receipt.accepted", "Command received")
                        : ConversationL10n.value("conversation.receipt.applied", "Command applied"),
                    style: receipt.state == .accepted ? .accepted : .receipt
                )
            }
            if let errorMessage = model.errorMessage {
                ConversationNoticeView(text: errorMessage, style: .warning)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let receipt = model.lastReceipt, receipt.state == .uncertain {
                ConversationNoticeView(text: receipt.reason ?? "The command outcome is unknown.", style: .uncertain)
            }
            ConversationComposerArea(model: model)
        }
        .background(Color(uiColor: .systemBackground))
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showsFiles) {
            ConversationFilesSheet(items: model.items, capabilities: model.capabilities)
        }
        .sheet(isPresented: $showsModelSettings) {
            ConversationModelSettingsSheet(model: model)
        }
        .confirmationDialog(ConversationL10n.value("conversation.task_actions", "Task actions"), isPresented: $showsMore, titleVisibility: .visible) {
            Button(ConversationL10n.value("conversation.refresh", "Refresh task")) { model.refreshSessions() }
            Button(ConversationL10n.value("conversation.close_task", "Close task"), role: .cancel) { model.selectSession(id: nil) }
        }
        // Keep the detail landmark while preserving the explicit identifiers
        // on its controls and transcript descendants for VoiceOver and UI
        // automation. Without containment, iPadOS propagates this identifier
        // to every descendant and hides the child targets.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ConversationDetail")
    }
}

private struct ConversationHeaderView: View {
    @Bindable var model: ConversationModel
    @Binding var showsFiles: Bool
    @Binding var showsModelSettings: Bool
    @Binding var showsMore: Bool

    private var session: ConversationSession? {
        guard let id = model.selectedSessionID else { return nil }
        return model.sessions.first(where: { $0.id == id })
    }

    var body: some View {
        HStack(spacing: 12) {
            Button {
                model.selectSession(id: nil)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.headline.weight(.semibold))
                    .frame(width: 34, height: 34)
                    .background(.thinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(ConversationL10n.value("conversation.back", "Back to tasks"))
            .accessibilityIdentifier("ConversationBackButton")

            VStack(alignment: .leading, spacing: 2) {
                Text(session?.title ?? ConversationL10n.value("conversation.title", "Conversation"))
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(session?.provider.displayName ?? ConversationL10n.value("conversation.codex", "Codex"))
                    Text("·")
                    Text(session?.workspaceDisplayName ?? ConversationL10n.value("conversation.cloud", "Cloud"))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 4)
            if model.connectionState != .connected {
                Image(systemName: "circle.slash")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(ConversationL10n.value("conversation.disconnected", "Disconnected"))
            }
            Menu {
                if model.supportsFiles {
                    Button(ConversationL10n.value("conversation.files", "Files"), systemImage: "doc.text.magnifyingglass") { showsFiles = true }
                }
                if model.supportsSettings {
                    Button(ConversationL10n.value("conversation.model_effort", "Model and effort"), systemImage: "slider.horizontal.3") { showsModelSettings = true }
                }
                Divider()
                Button(ConversationL10n.value("conversation.more", "More actions"), systemImage: "ellipsis") { showsMore = true }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.headline.weight(.semibold))
                    .frame(width: 36, height: 34)
            }
            .accessibilityLabel(ConversationL10n.value("conversation.actions", "Conversation actions"))
            .accessibilityIdentifier("ConversationActionsMenu")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

private struct ConversationNoticeView: View {
    enum Style { case warning, uncertain, accepted, receipt }
    let text: String
    let style: Style

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: style == .uncertain ? "questionmark.circle" : style == .receipt ? "checkmark.circle" : style == .accepted ? "arrow.down.circle" : "exclamationmark.triangle")
            Text(text)
                .font(.footnote)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .foregroundStyle(style == .uncertain ? .orange : style == .receipt ? .green : style == .accepted ? .blue : .secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.thinMaterial)
        .accessibilityIdentifier(style == .uncertain ? "ConversationUncertainReceipt" : style == .receipt ? "ConversationReceiptApplied" : style == .accepted ? "ConversationReceiptAccepted" : "ConversationErrorNotice")
    }
}

#endif
