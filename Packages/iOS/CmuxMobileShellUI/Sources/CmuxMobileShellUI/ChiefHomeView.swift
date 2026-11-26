import CmuxConversationCore
import CmuxConversationUI
import CmuxMobileShell
import CmuxMobileSupport
import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The Messages-style Home destination for a Mac's Chief conversations.
///
/// Chief is a Mac-owned service, so the Home list is intentionally backed by
/// the selected Mac's mobile RPC client. The pinned card and transcript use
/// the same visual language as the iMessage conversation package while the
/// surrounding shell keeps its existing workspace/feed/cloud destinations.
struct ChiefHomeView: View {
    let client: MobileChiefClient
    @Environment(\.scenePhase) private var scenePhase
    @State private var conversations: [MobileChiefConversation] = []
    @State private var isLoading = true
    @State private var requestInFlight = false
    @State private var errorMessage: String?
    @State private var query = ""
    @State private var changeCursor: String?

    private var pinnedConversation: MobileChiefConversation? {
        conversations.first(where: \.pinned) ?? conversations.first
    }

    private var visibleConversations: [MobileChiefConversation] {
        let pinnedID = pinnedConversation?.id
        return conversations.filter { conversation in
            conversation.id != pinnedID && matches(conversation)
        }
    }

    private var showsPinnedOnlyInvitation: Bool {
        guard let pinnedConversation else { return false }
        return matches(pinnedConversation) && visibleConversations.isEmpty
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && conversations.isEmpty {
                    ProgressView(L10n.string("mobile.chief.loading", defaultValue: "Loading Chief"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage, conversations.isEmpty {
                    ContentUnavailableView(
                        L10n.string("mobile.chief.unavailable.title", defaultValue: "Chief unavailable"),
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text(errorMessage)
                    )
                } else if conversations.isEmpty {
                    ContentUnavailableView(
                        L10n.string("mobile.chief.empty.title", defaultValue: "No Chief conversations"),
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text(L10n.string(
                            "mobile.chief.empty.message",
                            defaultValue: "Start a conversation from Chief on your Mac."
                        ))
                    )
                } else {
                    List {
                        if let pinned = pinnedConversation, matches(pinned) {
                            Section {
                                NavigationLink(value: pinned) {
                                    ChiefPinnedConversationCard(conversation: pinned)
                                }
                                .buttonStyle(.plain)
                                .listRowInsets(EdgeInsets())
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)

                                if showsPinnedOnlyInvitation {
                                    ChiefPinnedOnlyInvitation()
                                        .frame(maxWidth: .infinity)
                                        // A lone Chief card otherwise leaves a
                                        // large, unexplained hole above the
                                        // tab bar. Keep that space intentional
                                        // and bounded while giving the user a
                                        // useful next step.
                                        .frame(height: ChiefPinnedOnlyInvitation.height)
                                        .listRowInsets(EdgeInsets())
                                        .listRowSeparator(.hidden)
                                        .listRowBackground(Color.clear)
                                }
                            }
                        }

                        if !visibleConversations.isEmpty {
                            Section {
                                ForEach(visibleConversations) { conversation in
                                    NavigationLink(value: conversation) {
                                        ChiefConversationRow(conversation: conversation)
                                    }
                                    .buttonStyle(.plain)
                                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                                    .listRowBackground(Color.clear)
                                }
                            } header: {
                                Text(L10n.string(
                                    "mobile.chief.home.recent",
                                    defaultValue: "Recent conversations"
                                ))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16)
                                .padding(.top, 12)
                                .padding(.bottom, 8)
                            }
                            .textCase(nil)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
                    .refreshable { await load() }
                }
            }
            .navigationTitle(L10n.string("mobile.chief.home.title", defaultValue: "Home"))
            .searchable(
                text: $query,
                prompt: L10n.string("mobile.chief.home.search", defaultValue: "Search conversations")
            )
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await load() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel(L10n.string(
                        "mobile.chief.refresh",
                        defaultValue: "Refresh Chief conversations"
                    ))
                }
            }
            // Keep the Home list current while it is visible. The Mac holds
            // this request until its owner cursor changes, so previews, unread
            // counts, working state and in-place card updates arrive without
            // a fixed polling cadence.
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                await load()
                await waitForChanges()
            }
            .navigationDestination(for: MobileChiefConversation.self) { conversation in
                ChiefConversationDestination(client: client, conversation: conversation)
            }
        }
    }

    private func matches(_ conversation: MobileChiefConversation) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return conversation.title.localizedCaseInsensitiveContains(query)
            || conversation.preview.localizedCaseInsensitiveContains(query)
    }

    private func load() async {
        guard !requestInFlight else { return }
        requestInFlight = true
        isLoading = true
        defer {
            requestInFlight = false
            isLoading = false
        }
        do {
            let snapshot = try await client.conversationsSnapshot()
            changeCursor = snapshot.changeCursor
            var rows = snapshot.conversations
            var startupFailure: String?
            if rows.isEmpty {
                let status = try? await client.status()
                if let failure = status?.startFailure, !failure.isEmpty {
                    // Do not manufacture a tappable conversation when the
                    // Mac could not open Chief's home. The transcript would
                    // only fail later and hide the useful startup error.
                    startupFailure = failure
                } else if status?.started == true,
                          let id = status?.defaultConversation,
                          !id.isEmpty {
                    rows = [MobileChiefConversation(
                        id: id,
                        title: L10n.string("mobile.chief.name", defaultValue: "Chief"),
                        pinned: true
                    )]
                }
            }
            conversations = rows.sorted {
                if $0.pinned != $1.pinned { return $0.pinned && !$1.pinned }
                return $0.updatedAt > $1.updatedAt
            }
            errorMessage = startupFailure
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func waitForChanges() async {
        var consecutiveFailures = 0
        while !Task.isCancelled {
            if changeCursor == nil {
                // The initial snapshot can fail before it gives us a cursor.
                // Retry that load here so Home does not remain permanently
                // stale until the view is recreated.
                await load()
                guard !Task.isCancelled else { return }
                if changeCursor == nil {
                    consecutiveFailures = min(consecutiveFailures + 1, 10)
                    let delay = Duration.seconds(consecutiveFailures == 1 ? 1 : min(consecutiveFailures * 2, 30))
                    do {
                        try await ContinuousClock().sleep(for: delay)
                    } catch {
                        return
                    }
                    continue
                }
                consecutiveFailures = 0
            }
            do {
                let snapshot = try await client.conversationsSnapshot(
                    afterCursor: changeCursor,
                    waitForChange: true
                )
                guard !Task.isCancelled else { return }
                changeCursor = snapshot.changeCursor ?? changeCursor
                conversations = snapshot.conversations.sorted {
                    if $0.pinned != $1.pinned { return $0.pinned && !$1.pinned }
                    return $0.updatedAt > $1.updatedAt
                }
                errorMessage = nil
                consecutiveFailures = 0
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = String(describing: error)
                consecutiveFailures = min(consecutiveFailures + 1, 10)
                let delay = Duration.seconds(consecutiveFailures == 1 ? 1 : min(consecutiveFailures * 2, 30))
                do {
                    try await ContinuousClock().sleep(for: delay)
                } catch {
                    return
                }
            }
        }
    }

}

private struct ChiefPinnedConversationCard: View {
    let conversation: MobileChiefConversation

    var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topTrailing) {
                ChiefAvatarView(size: 88)
                if conversation.working {
                    ProgressView()
                        .tint(.white)
                        .padding(7)
                        .background(.orange, in: Circle())
                        .offset(x: 4, y: -4)
                } else if conversation.unread > 0 {
                    Text("\(conversation.unread)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(.blue, in: Capsule())
                        .offset(x: 8, y: -4)
                }
            }
            Text(conversation.title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.primary)
            Text(conversation.preview.isEmpty
                ? L10n.string("mobile.chief.home.ask", defaultValue: "Ask Chief anything")
                : conversation.preview)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 180)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
        .padding(.bottom, 16)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(pinnedAccessibilityLabel)
        .accessibilityIdentifier("MobileChiefPinnedConversation")
    }

    private var pinnedAccessibilityLabel: String {
        var values = [conversation.title]
        if !conversation.preview.isEmpty { values.append(conversation.preview) }
        if conversation.working {
            values.append(L10n.string("mobile.chief.working", defaultValue: "Working"))
        } else if conversation.unread > 0 {
            values.append(L10n.unreadLabel(count: conversation.unread))
        }
        return values.joined(separator: ", ")
    }
}

private struct ChiefPinnedOnlyInvitation: View {
    static let height: CGFloat = 480

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.blue)
                .accessibilityHidden(true)
            Text(L10n.string(
                "mobile.chief.home.ready.title",
                defaultValue: "Chief is ready when you are"
            ))
            .font(.headline)
            .multilineTextAlignment(.center)
            Text(L10n.string(
                "mobile.chief.home.ready.message",
                defaultValue: "Start a conversation from Chief on your Mac. New messages will appear here."
            ))
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 280)
        }
        .padding(.horizontal, 24)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("MobileChiefPinnedOnlyInvitation")
    }
}

private struct ChiefAvatarView: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(Color(uiColor: .secondarySystemBackground))
            if let image = UIImage(named: "ChiefAvatar", in: .module, compatibleWith: nil) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.08)
            } else {
                Image(systemName: "sparkles")
                    .font(.system(size: size * 0.38, weight: .semibold))
                    .foregroundStyle(.blue)
            }
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
    }
}

private struct ChiefConversationRow: View {
    let conversation: MobileChiefConversation

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                ChiefAvatarView(size: 45)
                if conversation.working {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(.orange, in: Circle())
                        .overlay(Circle().stroke(Color(uiColor: .systemGroupedBackground), lineWidth: 2))
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(conversation.title)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let stamp = relativeDate(conversation.updatedAt) {
                        Text(stamp)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                }
                HStack(alignment: .top, spacing: 6) {
                    Text(conversation.preview.isEmpty
                        ? L10n.string("mobile.chief.home.noMessages", defaultValue: "No messages yet")
                        : conversation.preview)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    if conversation.unread > 0 {
                        Circle()
                            .fill(.blue)
                            .frame(width: 7, height: 7)
                            .padding(.top, 6)
                            .accessibilityLabel(L10n.string("mobile.chief.unread", defaultValue: "Unread"))
                    }
                }
            }
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(rowAccessibilityLabel)
        .accessibilityIdentifier("MobileChiefConversationRow-\(conversation.id)")
    }

    private var rowAccessibilityLabel: String {
        var values = [conversation.title]
        if !conversation.preview.isEmpty { values.append(conversation.preview) }
        if conversation.working {
            values.append(L10n.string("mobile.chief.working", defaultValue: "Working"))
        } else if conversation.unread > 0 {
            values.append(L10n.unreadLabel(count: conversation.unread))
        }
        if let stamp = relativeDate(conversation.updatedAt) { values.append(stamp) }
        return values.joined(separator: ", ")
    }

    private func relativeDate(_ date: Date) -> String? {
        guard date != .distantPast else { return nil }
        return Self.relativeDateFormatter.localizedString(for: date, relativeTo: Date())
    }
}

#if canImport(UIKit)
private struct ChiefConversationDestination: View {
    let client: MobileChiefClient
    let conversation: MobileChiefConversation
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ChiefConversationControllerRepresentable(
            client: client,
            conversation: conversation,
            back: { dismiss() }
        )
        .ignoresSafeArea()
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .navigationBarBackButtonHidden()
    }
}

private struct ChiefConversationControllerRepresentable: UIViewControllerRepresentable {
    let client: MobileChiefClient
    let conversation: MobileChiefConversation
    let back: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(client: client, conversationID: conversation.id)
    }

    func makeUIViewController(context: Context) -> ConversationViewController {
        let backend = ChiefConversationBackend(
            client: client,
            conversationID: conversation.id,
            title: conversation.title
        )
        let store = ConversationStore(backend: backend)
        context.coordinator.store = store
        let controller = ConversationViewController(
            store: store,
            options: ConversationPresentationOptions(
                placeholder: L10n.string("mobile.chief.conversation.placeholder", defaultValue: "Message Chief"),
                serviceTitle: conversation.title,
                serviceSubtitle: L10n.string(
                    "mobile.chief.conversation.subtitle",
                    defaultValue: "Runs your agents on your Mac"
                ),
                avatarImage: UIImage(named: "ChiefAvatar", in: .module, compatibleWith: nil),
                unreadCount: conversation.unread,
                trailingSymbol: "stop.fill",
                trailingAccessibilityLabel: L10n.string(
                    "mobile.chief.conversation.stop",
                    defaultValue: "Stop Chief"
                ),
                supportsReactions: false,
                supportsEditing: false,
                supportsUnsend: false,
                supportsAttachments: false
            )
        )
        controller.onBack = back
        controller.onHeaderTrailing = {
            Task {
                _ = try? await client.stop(conversation: conversation.id)
            }
        }
        controller.onPollTapped = { [weak controller, weak backend] messageID, optionID in
            guard optionID == ChiefConversationBackend.questionComposerOptionID,
                  let controller,
                  let backend,
                  let question = backend.question(for: messageID) else { return false }
            let sheet = ChiefQuestionSheet(question: question) { choices, text in
                _ = try await backend.answerQuestion(messageID: messageID, choices: choices, text: text)
            }
            let host = UIHostingController(rootView: sheet)
            host.modalPresentationStyle = .pageSheet
            if let presentation = host.sheetPresentationController {
                presentation.detents = [.medium(), .large()]
                presentation.prefersGrabberVisible = true
            }
            controller.present(host, animated: true)
            return true
        }
        store.start()
        return controller
    }

    func updateUIViewController(_ uiViewController: ConversationViewController, context: Context) {
        uiViewController.onBack = back
    }

    static func dismantleUIViewController(
        _ uiViewController: ConversationViewController,
        coordinator: Coordinator
    ) {
        coordinator.store?.stop()
    }

    final class Coordinator: NSObject {
        let client: MobileChiefClient
        let conversationID: String
        var store: ConversationStore?

        init(client: MobileChiefClient, conversationID: String) {
            self.client = client
            self.conversationID = conversationID
        }
    }
}

private struct ChiefQuestionSheet: View {
    /// Matches `ChiefQuestionAnswer.qualifiedChoiceSeparator` on the Mac.
    /// Qualifying ids prevents identical option ids in different items from
    /// being assigned to the first matching question.
    private static let choiceSeparator = "\u{001F}"
    let question: MobileChiefQuestion
    let submit: ([String], String?) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selections: [String: Set<String>]
    @State private var otherText = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    init(
        question: MobileChiefQuestion,
        submit: @escaping ([String], String?) async throws -> Void
    ) {
        self.question = question
        self.submit = submit
        var initial: [String: Set<String>] = [:]
        for item in question.items {
            // Match Chief on macOS: the first option is the recommendation for
            // single-select items; multi-select items begin empty.
            if !item.multiSelect, let first = item.options.first {
                initial[item.id] = [first.id]
            } else {
                initial[item.id] = []
            }
        }
        _selections = State(initialValue: initial)
    }

    /// Mirrors `ChiefQuestionAnswer`: `chief.answer` carries one Other value,
    /// assigned to the first eligible unselected item, or the first eligible
    /// item as a fallback. The fallback keeps the field visible when a
    /// single-select item still carries Chief's default recommendation; typing
    /// clears that choice before submission, which is the server's Other path.
    private var otherTargetItem: MobileChiefQuestion.Item? {
        question.items.first(where: { item in
            item.allowsOther && (selections[item.id] ?? []).isEmpty
        }) ?? question.items.first(where: { $0.allowsOther })
    }

    private var selectedOtherText: String? {
        let text = otherText.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private var canSubmit: Bool {
        question.items.allSatisfy { item in
            let chosen = selections[item.id] ?? []
            let hasOther = item.id == otherTargetItem?.id && selectedOtherText != nil
            return !chosen.isEmpty || hasOther
        }
    }

    private var choices: [String] {
        question.items.flatMap { item in
            item.options.compactMap { option in
                selections[item.id]?.contains(option.id) == true
                    ? item.id + Self.choiceSeparator + option.id
                    : nil
            }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(
                            L10n.string("mobile.chief.question.needsInput", defaultValue: "Chief needs your input"),
                            systemImage: "sparkles"
                        )
                            .font(.headline)
                        Text(L10n.string(
                            "mobile.chief.question.instructions",
                            defaultValue: "Choose an answer for each question before sending it back to your Mac."
                        ))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if otherTargetItem != nil {
                            Text(L10n.string(
                                "mobile.chief.question.otherHint",
                                defaultValue: "You can type one custom answer; it is sent to the first question that accepts it."
                            ))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    ForEach(question.items) { item in
                        itemView(item)
                    }

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("MobileChiefQuestionError")
                    }
                }
                .padding(20)
            }
            .navigationTitle(L10n.string("mobile.chief.question.title", defaultValue: "Answer Chief"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("mobile.chief.cancel", defaultValue: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(question.submitLabel ?? L10n.string("mobile.chief.send", defaultValue: "Send")) {
                        Task { await submitAnswer() }
                    }
                    .disabled(!canSubmit || isSubmitting)
                }
            }
            .interactiveDismissDisabled(isSubmitting)
        }
        .accessibilityIdentifier("MobileChiefQuestionSheet")
    }

    @ViewBuilder
    private func itemView(_ item: MobileChiefQuestion.Item) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let header = item.header, !header.isEmpty {
                Text(header)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(item.prompt)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            if item.multiSelect {
                Text(L10n.string(
                    "mobile.chief.question.selectAll",
                    defaultValue: "Select all that apply"
                ))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                ForEach(Array(item.options.enumerated()), id: \.element.id) { index, option in
                    Button {
                        toggle(option.id, in: item)
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: isSelected(option.id, in: item)
                                ? (item.multiSelect ? "checkmark.square.fill" : "checkmark.circle.fill")
                                : (item.multiSelect ? "square" : "circle"))
                                .foregroundStyle(isSelected(option.id, in: item) ? Color.accentColor : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.label)
                                    .foregroundStyle(.primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if let detail = option.detail, !detail.isEmpty {
                                    Text(detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("MobileChiefQuestionOption-\(item.id)-\(option.id)")
                    if index < item.options.count - 1 {
                        Divider().padding(.leading, 32)
                    }
                }
            }
            .padding(.horizontal, 12)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            if item.id == otherTargetItem?.id {
                TextField(
                    L10n.string("mobile.chief.question.otherPlaceholder", defaultValue: "Other answer (optional)"),
                    text: $otherText,
                    axis: .vertical
                )
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: otherText) { _, value in
                        if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !item.multiSelect {
                            selections[item.id] = []
                        }
                    }
                    .accessibilityIdentifier("MobileChiefQuestionOther-\(item.id)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("MobileChiefQuestionItem-\(item.id)")
    }

    private func isSelected(_ optionID: String, in item: MobileChiefQuestion.Item) -> Bool {
        selections[item.id]?.contains(optionID) == true
    }

    private func toggle(_ optionID: String, in item: MobileChiefQuestion.Item) {
        var chosen = selections[item.id] ?? []
        if item.multiSelect {
            if chosen.contains(optionID) { chosen.remove(optionID) } else { chosen.insert(optionID) }
        } else {
            chosen = [optionID]
            if item.id == otherTargetItem?.id { otherText = "" }
        }
        selections[item.id] = chosen
    }

    private func submitAnswer() async {
        guard canSubmit else { return }
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        do {
            try await submit(choices, selectedOtherText)
            dismiss()
        } catch {
            errorMessage = String(describing: error)
        }
    }
}
#endif
