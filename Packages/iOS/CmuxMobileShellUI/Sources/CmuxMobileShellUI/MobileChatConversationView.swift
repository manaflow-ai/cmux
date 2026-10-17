import CmuxAgentChat
import PhotosUI
import SwiftUI
import UIKit

/// A focused transcript view with a native multiline composer.
struct MobileChatConversationView: View {
    let sessionID: String
    let model: MobileChatHomeModel
    let onBack: () -> Void
    let onMenu: () -> Void

    @State private var composerText = ""
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var pendingAttachments: [MobileChatComposerAttachment] = []
    @State private var isLoadingAttachment = false
    @FocusState private var composerFocused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if let session {
                        MobileChatConversationContext(
                            provider: provider,
                            workingDirectory: session.workingDirectory,
                            state: sessionState
                        )
                    }
                    if model.hasMoreHistory(for: sessionID) {
                        Button {
                            model.loadOlderHistory(sessionID: sessionID)
                        } label: {
                            HStack(spacing: 7) {
                                if model.isLoadingOlderHistory(for: sessionID) {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                                Text(
                                    model.isLoadingOlderHistory(for: sessionID)
                                        ? "Loading earlier messages…"
                                        : "Show earlier messages"
                                )
                                .font(.caption.weight(.semibold))
                            }
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                        }
                        .buttonStyle(.plain)
                        .disabled(model.isLoadingOlderHistory(for: sessionID))
                        .accessibilityIdentifier("MobileChatLoadEarlier")
                    }
                    if model.loadingSessionIDs.contains(sessionID) && model.messages(for: sessionID).isEmpty {
                        ProgressView("Loading conversation…")
                            .frame(maxWidth: .infinity)
                            .padding(.top, 28)
                    }
                    ForEach(model.messages(for: sessionID)) { message in
                        MobileChatMessageRow(message: message) { optionIndex in
                            Task { await model.answer(optionIndex: optionIndex, in: sessionID) }
                        }
                        .id(message.id)
                    }
                    if model.messages(for: sessionID).isEmpty,
                       !model.loadingSessionIDs.contains(sessionID) {
                        Text("Send a message to get started.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 20)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: model.messages(for: sessionID).last) { _, message in
                guard let message else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(message.id, anchor: .bottom)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            MobileChatComposer(
                text: $composerText,
                isFocused: $composerFocused,
                isWorking: isWorking,
                providerTitle: provider?.title ?? "your agent",
                selectedPhotos: $selectedPhotos,
                attachments: pendingAttachments,
                isLoadingAttachment: isLoadingAttachment,
                onSend: send,
                onRemoveAttachment: removeAttachment,
                onStop: {
                    Task { await model.interrupt(sessionID: sessionID) }
                }
            )
        }
        .navigationTitle(sessionTitle)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.body.weight(.semibold))
                }
                .accessibilityLabel("Back to chats")
                .accessibilityIdentifier("MobileChatBackToChats")
            }
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 8) {
                    if let provider {
                        MobileChatProviderBadge(provider: provider, size: 26)
                        Text(provider.title)
                            .font(.subheadline.weight(.semibold))
                    }
                    Menu {
                        Button("Copy conversation", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = model.copyText(for: sessionID)
                        }
                        .accessibilityIdentifier("MobileChatCopyConversation")
                        Button("Choose computer", systemImage: "desktopcomputer") { onMenu() }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.body.weight(.semibold))
                            .frame(width: 28, height: 28)
                    }
                    .accessibilityIdentifier("MobileChatConversationMenu")
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(provider.map { "\($0.title), \(sessionState.displayName)" } ?? "Chat")
            }
        }
        .task(id: sessionID) {
            model.open(sessionID: sessionID)
        }
        .onChange(of: selectedPhotos) { _, items in
            guard !items.isEmpty else { return }
            Task { await loadPhotos(items) }
        }
        .onDisappear {
            model.close(sessionID: sessionID)
        }
    }

    private var session: ChatSessionDescriptor? {
        model.sessions.first { $0.id == sessionID }
    }

    private var provider: MobileChatProvider? {
        session.flatMap { MobileChatProvider.resolve($0.agentKind) }
    }

    private var sessionTitle: String {
        if let title = session?.title, !title.isEmpty { return title }
        return provider.map { "New \($0.title) chat" } ?? "Chat"
    }

    private var sessionState: ChatAgentState {
        session?.state ?? .idle
    }

    private var isWorking: Bool {
        if case .working = sessionState { return true }
        return false
    }

    private func send() {
        let text = composerText
        let attachments = pendingAttachments
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty else {
            return
        }
        composerText = ""
        pendingAttachments.removeAll()
        composerFocused = false
        Task { @MainActor in
            let didSend = await model.send(
                text,
                attachments: attachments.map(\.outbound),
                to: sessionID
            )
            if !didSend {
                pendingAttachments.insert(contentsOf: attachments, at: 0)
                composerText = text
            }
        }
    }

    private func loadPhotos(_ items: [PhotosPickerItem]) async {
        isLoadingAttachment = true
        defer {
            selectedPhotos = []
            isLoadingAttachment = false
        }
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else { continue }
            if let jpeg = image.jpegData(compressionQuality: 0.86) {
                pendingAttachments.append(
                    MobileChatComposerAttachment(
                        image: image,
                        outbound: ChatOutboundAttachment(data: jpeg, format: .jpeg)
                    )
                )
            } else if let png = image.pngData() {
                pendingAttachments.append(
                    MobileChatComposerAttachment(
                        image: image,
                        outbound: ChatOutboundAttachment(data: png, format: .png)
                    )
                )
            }
        }
    }

    private func removeAttachment(_ attachment: MobileChatComposerAttachment) {
        pendingAttachments.removeAll { $0.id == attachment.id }
    }
}

private struct MobileChatComposer: View {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    let isWorking: Bool
    let providerTitle: String
    @Binding var selectedPhotos: [PhotosPickerItem]
    let attachments: [MobileChatComposerAttachment]
    let isLoadingAttachment: Bool
    let onSend: () -> Void
    let onRemoveAttachment: (MobileChatComposerAttachment) -> Void
    let onStop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isLoadingAttachment || !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(attachments) { attachment in
                            MobileChatAttachmentPreview(
                                attachment: attachment,
                                onRemove: { onRemoveAttachment(attachment) }
                            )
                        }
                        if isLoadingAttachment {
                            ProgressView()
                                .frame(width: 52, height: 52)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .accessibilityLabel("Loading attachment")
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
            HStack(alignment: .bottom, spacing: 9) {
                Menu {
                    PhotosPicker(
                        selection: $selectedPhotos,
                        maxSelectionCount: 4,
                        matching: .images,
                        photoLibrary: .shared()
                    ) {
                        Label("Photo library", systemImage: "photo")
                    }
                    Button("Open computer", systemImage: "desktopcomputer") { }
                        .disabled(true)
                } label: {
                    Image(systemName: "plus")
                        .font(.body.weight(.medium))
                        .frame(width: 30, height: 30)
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Add attachment")
                .accessibilityIdentifier("MobileChatAdd")
                TextField("Message \(providerTitle)", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .focused(isFocused)
                    .submitLabel(.send)
                    .onSubmit(onSend)
                    .frame(minHeight: 30)
                    .accessibilityLabel("Message \(providerTitle)")
                    .accessibilityIdentifier("MobileChatComposer")
                if isWorking {
                    Button(action: onStop) {
                        Image(systemName: "stop.fill")
                            .font(.caption.weight(.bold))
                            .frame(width: 34, height: 34)
                            .foregroundStyle(.white)
                            .background(.red, in: Circle())
                    }
                    .accessibilityLabel("Stop agent")
                    .accessibilityIdentifier("MobileChatStop")
                } else {
                    Button(action: onSend) {
                        Image(systemName: "arrow.up")
                            .font(.caption.weight(.bold))
                            .frame(width: 34, height: 34)
                            .foregroundStyle(.white)
                            .background(Color.accentColor, in: Circle())
                    }
                    .disabled(
                        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            && attachments.isEmpty
                    )
                    .accessibilityLabel("Send message")
                    .accessibilityIdentifier("MobileChatSend")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 23, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 23, style: .continuous).stroke(.separator.opacity(0.65), lineWidth: 0.7))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

private struct MobileChatComposerAttachment: Identifiable {
    let id = UUID()
    let image: UIImage
    let outbound: ChatOutboundAttachment
}

private struct MobileChatAttachmentPreview: View {
    let attachment: MobileChatComposerAttachment
    let onRemove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(uiImage: attachment.image)
                .resizable()
                .scaledToFill()
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.primary)
                    .frame(width: 19, height: 19)
                    .background(.regularMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove attachment")
        }
        .accessibilityElement(children: .contain)
    }
}

private struct MobileChatConversationContext: View {
    let provider: MobileChatProvider?
    let workingDirectory: String?
    let state: ChatAgentState

    var body: some View {
        HStack(spacing: 8) {
            if let provider {
                MobileChatProviderBadge(provider: provider, size: 24)
            }
            if let workingDirectory, !workingDirectory.isEmpty {
                Text(workingDirectory)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("Remote coding session")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            MobileChatStateDot(state: state)
            Text(state.displayName)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.thinMaterial, in: Capsule())
        .accessibilityIdentifier("MobileChatConversationContext")
    }
}
