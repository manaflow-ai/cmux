#if os(iOS)
import CmuxConversation
import SwiftUI

struct ConversationTranscriptView: View {
    @Bindable var model: ConversationModel
    @State private var expandedItems: Set<ConversationItemID> = []

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if model.items.isEmpty && model.requests.isEmpty && model.queue.isEmpty {
                        ConversationWelcomeView(provider: model.sessions.first(where: { $0.id == model.selectedSessionID })?.provider ?? .codex)
                            .padding(.top, 56)
                    }
                    ForEach(model.items) { item in
                        ConversationItemRow(item: item, model: model, isExpanded: expandedItems.contains(item.id)) {
                            if expandedItems.contains(item.id) { expandedItems.remove(item.id) }
                            else { expandedItems.insert(item.id) }
                        }
                        .id(item.id)
                    }
                    ForEach(model.queue) { queued in
                        ConversationQueuedRow(item: queued, model: model)
                            .id("queue-\(queued.id.rawValue)")
                    }
                    if let request = model.asynchronousRequest {
                        ConversationQuestionCard(request: request, model: model, isBlocking: false)
                            .id("request-\(request.id.rawValue)")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom)
            .onChange(of: model.items.count) { _, _ in
                if let id = model.items.last?.id { withAnimation(.snappy) { proxy.scrollTo(id, anchor: .bottom) } }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("ConversationTranscript")
        }
    }
}

private struct ConversationWelcomeView: View {
    let provider: ConversationProvider

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(.blue)
            Text("conversation.welcome.title \(provider.displayName)", bundle: .module)
                .font(.title3.weight(.semibold))
            Text(ConversationL10n.value("conversation.welcome.body", "Send an instruction to start a task. You can queue follow-ups, review tool work, and answer requests here."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 310)
        }
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("ConversationWelcome")
    }
}

private struct ConversationItemRow: View {
    let item: ConversationItem
    @Bindable var model: ConversationModel
    let isExpanded: Bool
    let toggle: () -> Void

    private var isUser: Bool { item.kind == .message && item.role?.lowercased() == "user" }
    private var isCollapsible: Bool { [.reasoning, .plan, .tool, .result, .files, .artifact, .child, .usage].contains(item.kind) }

    private var testIdentifier: String {
        switch item.kind {
        case .tool: return "ConversationTool-\(item.tool?.name ?? item.id.rawValue)"
        case .reasoning: return "ConversationReasoning-\(item.id.rawValue)"
        case .plan: return "ConversationPlan-\(item.id.rawValue)"
        case .result: return "ConversationResult-\(item.id.rawValue)"
        case .files: return "ConversationFilesItem-\(item.id.rawValue)"
        case .artifact: return "ConversationArtifact-\(item.artifact?.artifactID ?? item.id.rawValue)"
        default: return "ConversationItem-\(item.id.rawValue)"
        }
    }

    var body: some View {
        Group {
            if isUser {
                HStack {
                    Spacer(minLength: 44)
                    Text(item.displayText)
                        .font(.body)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
            } else if isCollapsible {
                Button(action: toggle) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: iconName)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(statusColor)
                            Text(item.displayTitle)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Spacer()
                            Text(statusLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        // Keep a compact result summary in the collapsed
                        // transcript.  Besides making the latest outcome
                        // scannable, this gives VoiceOver and UI automation a
                        // stable text target while the full detail remains
                        // available through expansion.
                        if item.kind == .result, !item.displayText.isEmpty {
                            Text(item.displayText)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        if isExpanded { detailView }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    if item.kind == .error { Label(ConversationL10n.value("conversation.error", "Error"), systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.subheadline.weight(.semibold)) }
                    Text(item.displayText)
                        .font(.body)
                        .foregroundStyle(item.kind == .error ? .red : .primary)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityIdentifier(testIdentifier)
    }

    private var iconName: String {
        switch item.kind {
        case .reasoning: "brain.head.profile"
        case .plan: "checklist"
        case .tool: "terminal"
        case .result: "checkmark.circle"
        case .files: "doc.text"
        case .artifact: "paperclip"
        case .child: "arrow.branch"
        case .usage: "chart.bar"
        default: "circle"
        }
    }

    private var statusLabel: String {
        if let tool = item.tool {
            switch tool.status {
            case .queued: ConversationL10n.value("conversation.queued", "Queued")
            case .running: ConversationL10n.value("conversation.running", "Running")
            case .success: ConversationL10n.value("conversation.success", "Success")
            case .failed: ConversationL10n.value("conversation.failed", "Failed")
            case .cancelled: ConversationL10n.value("conversation.cancelled", "Cancelled")
            case .unknown: ""
            }
        } else if item.kind == .reasoning { ConversationL10n.value("conversation.worked", "Worked") } else { "" }
    }

    private var statusColor: Color {
        if item.tool?.status == .failed || item.kind == .error { return .red }
        if item.tool?.status == .running { return .orange }
        if item.tool?.status == .success { return .green }
        return .secondary
    }

    @ViewBuilder
    private var detailView: some View {
        if item.kind == .files, let diff = item.diff {
            ConversationDiffView(diff: diff)
        } else if item.kind == .artifact, let artifact = item.artifact {
            ConversationArtifactPreview(artifact: artifact, model: model)
        } else if let tool = item.tool {
            VStack(alignment: .leading, spacing: 8) {
                if let input = tool.input { ConversationCodeBlock(text: input.prettyDescription, label: ConversationL10n.value("conversation.input", "Input")) }
                if let output = tool.output { ConversationCodeBlock(text: output.prettyDescription, label: ConversationL10n.value("conversation.output", "Output")) }
            }
        } else {
            Text(item.displayText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}

private struct ConversationArtifactPreview: View {
    let artifact: ConversationArtifact
    @Bindable var model: ConversationModel
    @State private var isLoading = false
    @State private var localURL: URL?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "doc")
                Text(artifact.fileName).lineLimit(1)
                Spacer()
                if let byteCount = artifact.byteCount {
                    Text(ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let localURL {
                ShareLink(item: localURL) { Label(ConversationL10n.value("conversation.share_artifact", "Share artifact"), systemImage: "square.and.arrow.up") }
                    .font(.subheadline)
                    .accessibilityIdentifier("ConversationArtifactShare-\(artifact.artifactID)")
            } else {
                Button {
                    isLoading = true
                    errorMessage = nil
                    Task {
                        do { localURL = try await model.downloadArtifact(artifact) }
                        catch { errorMessage = error.localizedDescription }
                        isLoading = false
                    }
                } label: {
                    if isLoading { ProgressView().controlSize(.small) }
                    else { Label(ConversationL10n.value("conversation.preview_artifact", "Preview artifact"), systemImage: "arrow.down.circle") }
                }
                .disabled(isLoading)
                .accessibilityIdentifier("ConversationArtifactPreview-\(artifact.artifactID)")
            }
            if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(.red) }
        }
    }
}

struct ConversationCodeBlock: View {
    let text: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(9)
            .background(Color.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .foregroundStyle(.white)
        }
    }
}

private struct ConversationQueuedRow: View {
    let item: ConversationQueueItem
    @Bindable var model: ConversationModel
    @State private var isEditing = false
    @State private var text = ""

    var body: some View {
        HStack {
            Spacer(minLength: 44)
            VStack(alignment: .leading, spacing: 6) {
                Text(item.text)
                    .font(.body)
                    .foregroundStyle(.primary)
                HStack(spacing: 6) {
                    Text(item.isDelivering ? ConversationL10n.value("conversation.sending", "Sending") : ConversationL10n.value("conversation.queued", "Queued"))
                    Text("·")
                    Image(systemName: "ellipsis")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contextMenu {
                Button(ConversationL10n.value("conversation.edit", "Edit"), systemImage: "pencil") { text = item.text; isEditing = true }
                Button(ConversationL10n.value("conversation.steer_instead", "Steer instead"), systemImage: "arrow.turn.up.right") { model.steer(item.text) }
                Button(ConversationL10n.value("conversation.cancel", "Cancel"), systemImage: "xmark", role: .destructive) { model.cancelQueue(item) }
            }
            .sheet(isPresented: $isEditing) {
                NavigationStack {
                    Form { TextField(ConversationL10n.value("conversation.queued_message", "Queued message"), text: $text, axis: .vertical).lineLimit(3...8) }
                        .navigationTitle(ConversationL10n.value("conversation.edit_queued", "Edit queued message"))
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) { Button(ConversationL10n.value("conversation.cancel", "Cancel")) { isEditing = false } }
                            ToolbarItem(placement: .confirmationAction) { Button(ConversationL10n.value("conversation.save", "Save")) { model.editQueue(item, text: text); isEditing = false } }
                        }
                }
                .presentationDetents([.medium])
            }
        }
        // The queue row is one actionable context-menu target. Without an
        // explicit element boundary, SwiftUI copies the row identifier onto
        // every text and image child, leaving UI automation with several
        // indistinguishable matches on iPadOS.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.text)
        .accessibilityHint(ConversationL10n.value("conversation.queued.hint", "Long press for queued message actions"))
        .accessibilityIdentifier("ConversationQueuedRow-\(item.position)")
    }
}

#endif
