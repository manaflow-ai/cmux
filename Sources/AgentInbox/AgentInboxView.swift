import AppKit
import CMUXAgentLaunch
import CmuxAgentJournal
import SwiftUI

struct AgentInboxView: View {
    let items: [AgentInboxItem]
    let onDismiss: () -> Void
    let moveRequest: Int
    let submitRequest: Int

    @State private var query = ""
    @State private var selectedID: String?
    @State private var replyText = ""
    @State private var questionSelection: String?

    private var visibleItems: [AgentInboxItem] {
        AgentInboxProjection.filtered(items, query: query)
    }

    private var selectedItem: AgentInboxItem? {
        if let selectedID, let item = visibleItems.first(where: { $0.id == selectedID }) {
            return item
        }
        return visibleItems.first
    }

    private var selectedIndex: Int {
        guard let selectedID, let index = visibleItems.firstIndex(where: { $0.id == selectedID }) else {
            return 0
        }
        return index
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                inboxList
                    .frame(minWidth: 300, idealWidth: 350, maxWidth: 390)
                Divider()
                detail
                    .frame(minWidth: 390, idealWidth: 540, maxWidth: .infinity)
            }
        }
        .frame(minWidth: 720, idealWidth: 920, minHeight: 480, idealHeight: 620)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            selectFirstIfNeeded()
            markSelectedMessageRead()
        }
        .onChange(of: query) { _, _ in
            selectFirstIfNeeded()
        }
        .onChange(of: selectedID) { _, _ in
            replyText = ""
            questionSelection = nil
            markSelectedMessageRead()
        }
        .onChange(of: moveRequest) { oldValue, newValue in
            moveSelection(by: newValue - oldValue)
        }
        .onChange(of: submitRequest) { _, _ in
            activateSelectedItem()
        }
        .onExitCommand(perform: onDismiss)
        .onMoveCommand { direction in
            switch direction {
            case .up: moveSelection(by: -1)
            case .down: moveSelection(by: 1)
            default: break
            }
        }
        .onSubmit {
            activateSelectedItem()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "tray.full")
                .foregroundStyle(.secondary)
            TextField(
                String(localized: "agentInbox.search.placeholder", defaultValue: "Search agents, workspaces, and messages"),
                text: $query
            )
            .textFieldStyle(.roundedBorder)
            Text(String(localized: "agentInbox.title", defaultValue: "Agent Inbox"))
                .font(.headline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help(String(localized: "agentInbox.close.help", defaultValue: "Close Agent Inbox"))
        }
        .padding(12)
    }

    private var inboxList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if visibleItems.isEmpty {
                        Text(String(localized: "agentInbox.empty", defaultValue: "No agent activity"))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 120)
                    } else {
                        ForEach(visibleItems) { item in
                            AgentInboxRow(
                                item: item,
                                isSelected: item.id == selectedItem?.id,
                                onSelect: { selectedID = item.id },
                                onActivate: { activate(item) }
                            )
                            .id(item.id)
                            Divider()
                        }
                    }
                }
            }
            .onChange(of: selectedID) { _, newValue in
                if let newValue {
                    withAnimation(.snappy(duration: 0.12)) {
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                }
            }
        }
        .background(Color.primary.opacity(0.025))
    }

    @ViewBuilder
    private var detail: some View {
        if let item = selectedItem {
            VStack(alignment: .leading, spacing: 0) {
                detailHeader(item)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let prompt = item.promptText, !prompt.isEmpty {
                            exchangeBlock(
                                label: String(localized: "agentInbox.you.label", defaultValue: "You"),
                                text: prompt,
                                tint: .secondary
                            )
                        }
                        exchangeBlock(
                            label: item.agentName,
                            text: item.agentText ?? item.preview,
                            tint: .accentColor
                        )
                        decisionControls(for: item)
                    }
                    .padding(18)
                }
                if canSendFreeText(item) {
                    Divider()
                    replyComposer(for: item)
                }
            }
            .onAppear { markSelectedMessageRead() }
        } else {
            ContentUnavailableView(
                String(localized: "agentInbox.select.title", defaultValue: "Select an agent update"),
                systemImage: "bubble.left.and.bubble.right",
                description: Text(String(localized: "agentInbox.select.description", defaultValue: "Choose an item to inspect its exchange."))
            )
        }
    }

    private func detailHeader(_ item: AgentInboxItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.kind.symbolName)
                .font(.title3)
                .foregroundStyle(item.kind.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title.isEmpty ? item.agentName : item.title)
                    .font(.headline)
                    .lineLimit(2)
                Text([item.agentName, item.workspaceTitle, item.createdAt.formatted(.relative(presentation: .named))]
                    .filter { !$0.isEmpty }
                    .joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let state = item.state {
                Text(state.localizedLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
    }

    private func exchangeBlock(label: String, text: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: label.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
            Text(verbatim: text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder
    private func decisionControls(for item: AgentInboxItem) -> some View {
        let actions = FeedRowActions.bound()
        if !item.permissionModes.isEmpty {
            decisionButtons(
                title: String(localized: "agentInbox.permission.title", defaultValue: "Permission"),
                labels: item.permissionModes.map(\.localizedLabel),
                action: { index in
                    actions.approvePermission(itemID(for: item), item.permissionModes[index])
                    onDismiss()
                }
            )
        } else if !item.planModes.isEmpty {
            decisionButtons(
                title: String(localized: "agentInbox.plan.title", defaultValue: "Plan approval"),
                labels: item.planModes.map(\.localizedLabel),
                action: { index in
                    actions.approveExitPlan(itemID(for: item), item.planModes[index], nil)
                    onDismiss()
                }
            )
        } else if !item.questionOptions.isEmpty {
            decisionButtons(
                title: String(localized: "agentInbox.question.title", defaultValue: "Choose an answer"),
                labels: item.questionOptions.enumerated().map { "\($0.offset + 1). \($0.element.label)" },
                action: { index in
                    questionSelection = item.questionOptions[index].id
                    actions.replyQuestion(itemID(for: item), [item.questionOptions[index].label])
                    onDismiss()
                }
            )
        }
    }

    private func decisionButtons(title: String, labels: [String], action: @escaping (Int) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: title)
                .font(.subheadline.weight(.semibold))
            HStack(spacing: 8) {
                ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
                    Button(label) { action(index) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(index < 9 ? KeyEquivalent(Character(String(index + 1))) : KeyEquivalent("\0"), modifiers: [])
                }
            }
        }
    }

    private func replyComposer(for item: AgentInboxItem) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(
                String(localized: "agentInbox.reply.placeholder", defaultValue: "Reply to this agent"),
                text: $replyText,
                axis: .vertical
            )
            .lineLimit(1...5)
            .textFieldStyle(.roundedBorder)
            Button(String(localized: "agentInbox.send", defaultValue: "Send")) {
                sendReply(for: item)
            }
            .buttonStyle(.borderedProminent)
            .disabled(replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(12)
    }

    private func canSendFreeText(_ item: AgentInboxItem) -> Bool {
        switch item.replyTarget {
        case .agentMessage, .workstream: return true
        case .feed, nil: return false
        }
    }

    private func sendReply(for item: AgentInboxItem) {
        let body = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        switch item.replyTarget {
        case let .agentMessage(surfaceId, workspaceId, replyTo):
            appendAgentMessage(
                body: body,
                recipientSurfaceId: surfaceId,
                recipientWorkspaceId: workspaceId,
                inReplyTo: replyTo
            )
        case let .workstream(workstreamID):
            guard let target = FeedJumpResolver.resolve(workstreamID) else { return }
            appendAgentMessage(
                body: body,
                recipientSurfaceId: target.surfaceId,
                recipientWorkspaceId: target.workspaceId,
                inReplyTo: nil
            )
        case .feed, nil:
            return
        }
        replyText = ""
    }

    private func appendAgentMessage(
        body: String,
        recipientSurfaceId: String,
        recipientWorkspaceId: String?,
        inReplyTo: String?
    ) {
        let senderName = NSFullUserName().isEmpty
            ? String(localized: "agentInbox.you.senderName", defaultValue: "you")
            : NSFullUserName()
        let draft = AgentMessageDraft(
            senderName: senderName,
            senderSurfaceId: nil,
            senderWorkspaceId: nil,
            recipientSurfaceId: recipientSurfaceId,
            recipientWorkspaceId: recipientWorkspaceId,
            body: body,
            threadId: nil,
            inReplyTo: inReplyTo
        )
        _ = try? AgentMessageCenter.store.append(draft)
    }

    private func itemID(for item: AgentInboxItem) -> UUID {
        guard case let .feed(id) = item.replyTarget else { return UUID() }
        return id
    }

    private func selectFirstIfNeeded() {
        guard !visibleItems.isEmpty else {
            selectedID = nil
            return
        }
        guard let selectedID, visibleItems.contains(where: { $0.id == selectedID }) else {
            selectedID = visibleItems[0].id
            return
        }
    }

    private func moveSelection(by delta: Int) {
        guard !visibleItems.isEmpty else { return }
        let index = min(max(selectedIndex + delta, 0), visibleItems.count - 1)
        selectedID = visibleItems[index].id
    }

    private func activateSelectedItem() {
        guard let item = selectedItem else { return }
        activate(item)
    }

    private func activate(_ item: AgentInboxItem) {
        if item.permissionModes.isEmpty && item.planModes.isEmpty && item.questionOptions.isEmpty,
           let workstreamID = item.workstreamId {
            FeedRowActions.bound().jump(workstreamID)
            onDismiss()
        }
    }

    private func markSelectedMessageRead() {
        guard let item = selectedItem, item.kind == .agentMessage else { return }
        let prefix = "message:"
        guard item.id.hasPrefix(prefix) else { return }
        _ = AgentMessageCenter.store.markRead(ids: [String(item.id.dropFirst(prefix.count))])
    }
}

private struct AgentInboxRow: View {
    let item: AgentInboxItem
    let isSelected: Bool
    let onSelect: () -> Void
    let onActivate: () -> Void

    var body: some View {
        Button(action: onActivate) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: item.kind.symbolName)
                    .foregroundStyle(item.kind.tint)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(verbatim: item.agentName)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        if item.isUnread {
                            Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                        }
                        Spacer()
                        Text(item.createdAt.formatted(.relative(presentation: .named)))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if !item.workspaceTitle.isEmpty {
                        Text(verbatim: item.workspaceTitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text(verbatim: item.preview)
                        .font(.caption)
                        .foregroundStyle(.primary.opacity(0.82))
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture().onEnded { onSelect() })
    }
}

private extension AgentInboxItemKind {
    var symbolName: String {
        switch self {
        case .agentMessage: return "bubble.left"
        case .permissionRequest: return "lock.shield"
        case .planApproval: return "checklist"
        case .question: return "questionmark.bubble"
        case .finishedTurn: return "checkmark.circle"
        }
    }

    var tint: Color {
        switch self {
        case .agentMessage: return .blue
        case .permissionRequest: return .orange
        case .planApproval: return .purple
        case .question: return .cyan
        case .finishedTurn: return .green
        }
    }
}

private extension AgentMessageDeliveryState {
    var localizedLabel: String {
        switch self {
        case .queued: return String(localized: "agentInbox.state.queued", defaultValue: "Queued")
        case .delivered: return String(localized: "agentInbox.state.delivered", defaultValue: "Delivered")
        case .read: return String(localized: "agentInbox.state.read", defaultValue: "Read")
        }
    }
}

private extension WorkstreamPermissionMode {
    var localizedLabel: String {
        switch self {
        case .once: return String(localized: "agentInbox.permission.once", defaultValue: "Once")
        case .always: return String(localized: "agentInbox.permission.always", defaultValue: "Always")
        case .all: return String(localized: "agentInbox.permission.all", defaultValue: "All tools")
        case .bypass: return String(localized: "agentInbox.permission.bypass", defaultValue: "Bypass")
        case .deny: return String(localized: "agentInbox.permission.deny", defaultValue: "Deny")
        }
    }
}

private extension WorkstreamExitPlanMode {
    var localizedLabel: String {
        switch self {
        case .ultraplan: return String(localized: "agentInbox.plan.ultraplan", defaultValue: "Ultraplan")
        case .bypassPermissions: return String(localized: "agentInbox.plan.bypass", defaultValue: "Bypass")
        case .autoAccept: return String(localized: "agentInbox.plan.auto", defaultValue: "Auto")
        case .manual: return String(localized: "agentInbox.plan.manual", defaultValue: "Manual")
        case .deny: return String(localized: "agentInbox.plan.deny", defaultValue: "Deny")
        }
    }
}
