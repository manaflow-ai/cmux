import CMUXMobileCore
import CmuxAgentChat
import CmuxMobileSupport
import Foundation
import Observation
import SwiftUI

#if os(iOS)
import PhotosUI
import UIKit
#endif

public struct ChatComposerView: View {
    private let agentState: ChatAgentState
    private let agentKind: ChatAgentKind
    private let isTerminal: Bool
    private let isConnected: Bool
    private let accessoryLeadingShortcuts: [ChatAccessoryShortcut]
    private let accessoryShortcuts: [ChatAccessoryShortcut]
    private let onSend: (String, [ChatOutboundAttachment]) -> Void
    private let onInterrupt: (Bool) -> Void
    private let onOpenTerminal: () -> Void
    private let onDiagnosticEvent: (ChatConversationDiagnosticEvent) -> Void

    @Binding private var draft: String
    @State private var lastStopTap: Date?
    #if os(iOS)
    @FocusState private var isDraftFocused: Bool
    #endif
    @State private var attachmentStaging = ChatAttachmentStagingTaskOwner()
    #if os(iOS)
    @State private var pickedItems: [PhotosPickerItem] = []
    @State private var isPhotoPickerPresented = false
    @State private var attachments: [ChatComposerAttachment] = []
    @State private var dictation: ComposerDictationController
    #endif

    @Environment(\.chatTheme) private var theme

    @ScaledMetric(relativeTo: .title) private var sendButtonSize: CGFloat = 36
    private let controlHeight: CGFloat = 40

    private static let maxAttachmentDimension: CGFloat = 2048
    private static let jpegQuality: CGFloat = 0.85
    private static let hardStopWindow: TimeInterval = 2

    public init(
        agentState: ChatAgentState,
        agentKind: ChatAgentKind,
        isTerminal: Bool = false,
        isConnected: Bool,
        accessoryLeadingShortcuts: [ChatAccessoryShortcut] = [],
        accessoryShortcuts: [ChatAccessoryShortcut] = [],
        draft: Binding<String>,
        onSend: @escaping (String, [ChatOutboundAttachment]) -> Void,
        onInterrupt: @escaping (Bool) -> Void,
        onOpenTerminal: @escaping () -> Void,
        onDiagnosticEvent: @escaping (ChatConversationDiagnosticEvent) -> Void = { _ in },
        onDictationDiagnosticEvent: @escaping (ComposerDictationDiagnosticEvent) -> Void = { _ in }
    ) {
        self.agentState = agentState
        self.agentKind = agentKind
        self.isTerminal = isTerminal
        self.isConnected = isConnected
        self.accessoryLeadingShortcuts = accessoryLeadingShortcuts
        self.accessoryShortcuts = accessoryShortcuts
        _draft = draft
        self.onSend = onSend
        self.onInterrupt = onInterrupt
        self.onOpenTerminal = onOpenTerminal
        self.onDiagnosticEvent = onDiagnosticEvent
        #if os(iOS)
        _dictation = State(initialValue: ComposerDictationController { event in
            onDictationDiagnosticEvent(event)
        })
        #endif
    }

    public var body: some View {
        #if os(iOS)
        composerSurface
            .padding(.horizontal, theme.horizontalMargin)
            .padding(.top, 2)
            .padding(.bottom, 8)
            .modifier(ChatComposerMaterialBackground())
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("ChatComposerBar")
            #if DEBUG
            .background(ChatComposerDebugAutofocusBridge())
            #endif
            .onDisappear {
                attachmentStaging.cancel()
                dictation.cancel()
            }
            .onChange(of: isDraftFocused) { _, focused in
                if !focused, !dictation.locksComposerField {
                    dictation.stop()
                }
            }
        #else
        composerStack
            .padding(.horizontal, theme.horizontalMargin)
            .padding(.vertical, 8)
            .modifier(ChatComposerMaterialBackground())
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(theme.hairline)
                    .frame(height: 0.5)
            }
        #endif
    }

    #if os(iOS)
    @ViewBuilder
    private var composerSurface: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer {
                composerStack
            }
        } else {
            composerStack
        }
    }
    #endif

    private var composerStack: some View {
        VStack(spacing: 8) {
            if isEnded {
                endedRow
            } else {
                ChatAccessoryChipRow(
                    agentState: agentState,
                    leadingShortcuts: composerAccessoryLeadingShortcuts,
                    shortcuts: composerAccessoryShortcuts,
                    onInterrupt: onInterrupt,
                    onOpenTerminal: onOpenTerminal
                )
                #if os(iOS)
                if !attachments.isEmpty {
                    attachmentStrip
                }
                #endif
                fieldRow
            }
        }
    }

    private var composerAccessoryLeadingShortcuts: [ChatAccessoryShortcut] {
        #if os(iOS)
        remapComposerOwnedShortcuts(accessoryLeadingShortcuts)
        #else
        accessoryLeadingShortcuts
        #endif
    }

    private var composerAccessoryShortcuts: [ChatAccessoryShortcut] {
        #if os(iOS)
        remapComposerOwnedShortcuts(accessoryShortcuts)
        #else
        accessoryShortcuts
        #endif
    }

    #if os(iOS)
    private func remapComposerOwnedShortcuts(
        _ shortcuts: [ChatAccessoryShortcut]
    ) -> [ChatAccessoryShortcut] {
        shortcuts.map { shortcut in
            switch shortcut.semanticAction {
            case .dismissKeyboard:
                shortcut.replacingAction(dismissKeyboard)
            case .paste:
                shortcut.replacingAction(performPaste)
            case nil:
                shortcut
            }
        }
    }
    #endif

    // MARK: - Field row

    private var fieldRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            #if os(iOS)
            attachButton
            micButton
            #endif
            MobileComposerFieldContainer {
                TextField(placeholder, text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .font(isTerminal ? .system(.body, design: .monospaced) : .body)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("ChatComposerField")
                    .padding(.vertical, 3)
                    #if os(iOS)
                    .focused($isDraftFocused)
                    .disabled(dictation.locksComposerField)
                    #endif
            } trailing: {
                sendButton
            }
        }
    }

    private var placeholder: String {
        if isTerminal {
            return String(
                localized: "chat.composer.placeholder.terminal",
                defaultValue: "❯ command",
                bundle: .module
            )
        }
        return String(
            localized: "chat.composer.placeholder",
            defaultValue: "Message \(agentKind.displayName)",
            bundle: .module
        )
    }

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasContent: Bool {
        #if os(iOS)
        return !trimmedDraft.isEmpty || !attachments.isEmpty
        #else
        return !trimmedDraft.isEmpty
        #endif
    }

    private var isWorking: Bool {
        if case .working = agentState { return true }
        return false
    }

    private var isEnded: Bool {
        agentState == .ended
    }

    private var endedRow: some View {
        HStack(spacing: 12) {
            Text(
                String(
                    localized: "chat.composer.session_ended",
                    defaultValue: "Session ended",
                    bundle: .module
                )
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            Spacer()
            Button(action: onOpenTerminal) {
                Text(
                    String(
                        localized: "chat.composer.open_terminal",
                        defaultValue: "Open terminal",
                        bundle: .module
                    )
                )
                .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Send / stop button

    @ViewBuilder
    private var sendButton: some View {
        if hasContent {
            Button(action: performSend) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(isConnected ? Color.white : Color.secondary.opacity(0.35))
                    .frame(width: sendButtonSize - 8, height: sendButtonSize - 8)
                    .background(
                        Circle().fill(
                            isConnected
                                ? AnyShapeStyle(theme.accent)
                                : AnyShapeStyle(Color.secondary.opacity(0.12))
                        )
                    )
            }
            .buttonStyle(.plain)
            .disabled(!isConnected || attachmentStaging.isBusy)
            .accessibilityIdentifier("ChatComposerSend")
            .accessibilityLabel(
                String(
                    localized: "chat.composer.send.accessibility",
                    defaultValue: "Send",
                    bundle: .module
                )
            )
        } else if isWorking {
            Button(action: performStop) {
                ZStack {
                    Circle()
                        .fill(.red)
                    Image(systemName: "square.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.white)
                }
                .frame(width: sendButtonSize - 8, height: sendButtonSize - 8)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                String(
                    localized: "chat.composer.stop.accessibility",
                    defaultValue: "Stop",
                    bundle: .module
                )
            )
        } else {
            Button(action: performSend) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.secondary.opacity(0.35))
                    .frame(width: sendButtonSize - 8, height: sendButtonSize - 8)
                    .background(Circle().fill(Color.secondary.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .disabled(true)
            .accessibilityLabel(
                String(
                    localized: "chat.composer.send.accessibility",
                    defaultValue: "Send",
                    bundle: .module
                )
            )
        }
    }

    private func performSend() {
        guard hasContent, !attachmentStaging.isBusy else { return }
        #if os(iOS)
        dictation.cancel()
        let outbound = attachments.map(\.outbound)
        MobileHapticFeedback().impact(style: .light)
        #else
        let outbound: [ChatOutboundAttachment] = []
        #endif
        onSend(trimmedDraft, outbound)
        draft = ""
        #if os(iOS)
        attachmentStaging.cancel()
        attachments = []
        pickedItems = []
        #endif
    }

    private func performStop() {
        #if os(iOS)
        MobileHapticFeedback().impact(style: .rigid)
        #endif
        let now = Date()
        if let last = lastStopTap, now.timeIntervalSince(last) < Self.hardStopWindow {
            onInterrupt(true)
        } else {
            onInterrupt(false)
        }
        lastStopTap = now
    }

    // MARK: - Attachments (iOS)

    #if os(iOS)
    private func dismissKeyboard() {
        isDraftFocused = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func performPaste() {
        let pasteboard = UIPasteboard.general
        if attachmentStaging.canAcceptExternalAttachment,
           attachments.count < 4,
           let attachment = pasteboard.chatComposerAttachment(
               maxDimension: Self.maxAttachmentDimension,
               jpegQuality: Self.jpegQuality
           ) {
            attachments.append(attachment)
            onDiagnosticEvent(.composerAttachmentAdded(count: attachments.count))
            isDraftFocused = true
            return
        }
        guard let string = pasteboard.chatComposerText() else {
            return
        }
        draft += string
        isDraftFocused = true
    }

    private var attachButton: some View {
        Menu {
            Button {
                onDiagnosticEvent(.photoPickerOpened)
                isPhotoPickerPresented = true
            } label: {
                Label(
                    String(
                        localized: "chat.composer.attach.photo",
                        defaultValue: "Photo Library",
                        bundle: .module
                    ),
                    systemImage: "photo.on.rectangle"
                )
            }
            Button(action: performPaste) {
                Label(
                    String(
                        localized: "chat.composer.attach.paste",
                        defaultValue: "Paste Attachment",
                        bundle: .module
                    ),
                    systemImage: "doc.on.clipboard"
                )
            }
        } label: {
            MobileComposerIconLabel(
                systemImage: "paperclip",
                foregroundStyle: AnyShapeStyle(Color.secondary.opacity(0.8)),
                size: controlHeight
            )
        }
        .buttonStyle(.plain)
        .disabled(attachments.count >= 4)
        .accessibilityIdentifier("ChatComposerAttach")
        .accessibilityLabel(
            String(
                localized: "chat.composer.attach.accessibility",
                defaultValue: "Add attachment",
                bundle: .module
            )
        )
        .photosPicker(
            isPresented: $isPhotoPickerPresented,
            selection: $pickedItems,
            maxSelectionCount: max(4 - attachments.filter { $0.source == .pasteboard }.count, 1),
            matching: .images
        )
        .onChange(of: pickedItems) {
            let items = pickedItems
            guard !items.isEmpty else { return }
            onDiagnosticEvent(.photoPickerSelected(count: items.count))
            attachmentStaging.start { generation in
                await loadPickedItems(items, generation: generation)
            }
        }
        .onChange(of: isPhotoPickerPresented) { oldValue, isPresented in
            guard oldValue, !isPresented else { return }
            // PhotosPicker does not expose a semantic cancel callback and may
            // update selection after dismissal. Record only the observable
            // dismissal fact so a confirmed pick is never mislabeled.
            onDiagnosticEvent(.photoPickerDismissed)
        }
    }

    private var micButton: some View {
        let listening = dictation.state.isListening
        return MobileComposerIconButton(
            systemImage: "mic",
            activeSystemImage: "mic.fill",
            isActive: listening,
            foregroundStyle: listening ? AnyShapeStyle(Color.red) : AnyShapeStyle(Color.secondary.opacity(0.8)),
            size: controlHeight,
            pulsesWhenActive: true,
            isDisabled: !dictation.isAvailable,
            accessibilityIdentifier: "ChatComposerMic",
            accessibilityLabel: listening
                ? L10n.string("mobile.composer.mic.stop", defaultValue: "Stop dictation")
                : L10n.string("mobile.composer.mic.start", defaultValue: "Start dictation")
        ) {
            toggleDictation()
        }
    }

    private func toggleDictation() {
        dictation.toggle(existingText: draft) { merged in
            draft = merged
        }
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(attachments.enumerated()), id: \.element.id) { index, attachment in
                    attachment.thumbnail
                        .resizable()
                        .scaledToFill()
                        .frame(width: 60, height: 60)
                        .clipShape(.rect(cornerRadius: 10))
                        .overlay(alignment: .topTrailing) {
                            removeButton(id: attachment.id, index: index)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(
                            String(
                                localized: "chat.composer.attachment.accessibility",
                                defaultValue: "Attachment \(index + 1)",
                                bundle: .module
                            )
                        )
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func removeButton(id: String, index: Int) -> some View {
        Button {
            removeAttachment(id: id)
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(.white, .black.opacity(0.6))
                .padding(3)
                .frame(width: 44, height: 44, alignment: .topTrailing)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            String(
                localized: "chat.composer.remove_attachment.accessibility",
                defaultValue: "Remove attachment \(index + 1)",
                bundle: .module
            )
        )
    }

    private func removeAttachment(id: String) {
        guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }
        attachments.remove(at: index)
        onDiagnosticEvent(.composerAttachmentRemoved(count: attachments.count))
        if let pickedIndex = pickedItems.firstIndex(where: { $0.itemIdentifier == id }) {
            pickedItems.remove(at: pickedIndex)
        }
    }

    private func loadPickedItems(
        _ items: [PhotosPickerItem],
        generation: UUID
    ) async {
        var staged: [ChatComposerAttachment] = []
        for (index, item) in items.prefix(4).enumerated() {
            guard attachmentStaging.isCurrent(generation) else { return }
            onDiagnosticEvent(.composerAttachmentPreparationStarted)
            let data = try? await item.loadTransferable(type: Data.self)
            guard attachmentStaging.isCurrent(generation) else { return }
            guard let data else {
                onDiagnosticEvent(.composerAttachmentPreparationFailed)
                continue
            }
            let attachment = await Self.preparePickedAttachment(
                data: data,
                id: item.itemIdentifier ?? "picked-\(index)",
                maxDimension: Self.maxAttachmentDimension,
                jpegQuality: Self.jpegQuality
            )
            guard attachmentStaging.isCurrent(generation) else { return }
            guard let attachment else {
                onDiagnosticEvent(.composerAttachmentPreparationFailed)
                continue
            }
            staged.append(attachment)
            onDiagnosticEvent(
                .composerAttachmentPreparationSucceeded(byteCount: attachment.data.count)
            )
        }
        guard attachmentStaging.isCurrent(generation) else { return }
        let retained = attachments.filter { $0.source == .pasteboard }
        let accepted = Array(staged.prefix(max(4 - retained.count, 0)))
        attachments = retained + accepted
        if !accepted.isEmpty {
            onDiagnosticEvent(.composerAttachmentAdded(count: accepted.count))
        }
    }

    /// Decodes, downsizes, and encodes picker data on the generic executor.
    @concurrent
    private nonisolated static func preparePickedAttachment(
        data: Data,
        id: String,
        maxDimension: CGFloat,
        jpegQuality: CGFloat
    ) async -> ChatComposerAttachment? {
        guard !Task.isCancelled else { return nil }
        return data.chatComposerImageAttachment(
            id: id,
            maxDimension: maxDimension,
            jpegQuality: jpegQuality
        )
    }
    #endif
}

/// Owns one photo-staging operation across SwiftUI view-value recreation.
@MainActor
@Observable
final class ChatAttachmentStagingTaskOwner {
    private(set) var generation = UUID()
    private(set) var isBusy = false
    @ObservationIgnored private(set) var task: Task<Void, Never>?

    /// Photo staging reserves the remaining bounded attachment capacity until
    /// its selected items settle, so a concurrent paste cannot evict a pick.
    var canAcceptExternalAttachment: Bool {
        !isBusy
    }

    /// Replaces the current operation and binds its busy state to one generation.
    func start(
        _ operation: @escaping @MainActor (UUID) async -> Void
    ) {
        cancel()
        let generation = UUID()
        self.generation = generation
        isBusy = true
        task = Task { @MainActor [weak self] in
            await operation(generation)
            guard let self, self.generation == generation else { return }
            self.isBusy = false
            self.task = nil
        }
    }

    /// Returns whether the caller still owns the current staging operation.
    func isCurrent(_ generation: UUID) -> Bool {
        self.generation == generation && !Task.isCancelled
    }

    /// Cancels the owned task and synchronously releases composer busy state.
    func cancel() {
        generation = UUID()
        isBusy = false
        task?.cancel()
        task = nil
    }
}
