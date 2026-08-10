import CMUXMobileCore
import CmuxAgentChat
import CmuxMobileSupport
import Foundation
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

    @Binding private var draft: String
    @State private var lastStopTap: Date?
    #if os(iOS)
    @FocusState private var isDraftFocused: Bool
    #endif
    @State private var isStagingAttachments = false
    #if os(iOS)
    @State private var pickedItems: [PhotosPickerItem] = []
    @State private var attachments: [MobileStagedAttachment] = []
    @State private var isPhotoPickerPresented = false
    @State private var isFileImporterPresented = false
    @State private var attachmentError: String?
    @State private var attachmentStagingTask: Task<Void, Never>?
    @State private var attachmentStagingGeneration = UUID()
    @State private var dictation = ComposerDictationController()
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
        onOpenTerminal: @escaping () -> Void
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
                dictation.cancel()
                attachmentStagingTask?.cancel()
                attachmentStagingTask = nil
                attachmentStagingGeneration = UUID()
                isStagingAttachments = false
                removeUnsentAttachments()
            }
            .onChange(of: isDraftFocused) { _, focused in
                if !focused, !dictation.locksComposerField {
                    dictation.stop()
                }
            }
            .modifier(MobileAttachmentPickerModifier(
                isPhotoPickerPresented: $isPhotoPickerPresented,
                photoSelection: $pickedItems,
                isFileImporterPresented: $isFileImporterPresented,
                remainingCount: MobileStagedAttachment.maximumCount - attachments.count,
                selectedPhotos: startLoadingPickedItems,
                selectedFiles: startLoadingPickedFiles
            ))
            .alert(
                String(localized: "mobile.attachment.error.title", defaultValue: "Couldn’t Add Attachment", bundle: .module),
                isPresented: Binding(
                    get: { attachmentError != nil },
                    set: { if !$0 { attachmentError = nil } }
                )
            ) {
                Button(
                    String(localized: "mobile.attachment.error.ok", defaultValue: "OK", bundle: .module),
                    role: .cancel
                ) { attachmentError = nil }
            } message: {
                Text(attachmentError ?? "")
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
                if !attachments.isEmpty || isStagingAttachments {
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
            .disabled(!isConnected || isStagingAttachments)
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
        guard hasContent, !isStagingAttachments else { return }
        #if os(iOS)
        dictation.cancel()
        let outbound = attachments.map {
            ChatOutboundAttachment(
                localFileURL: $0.localFileURL,
                byteCount: $0.byteCount,
                fileName: $0.fileName,
                kind: $0.kind == .image ? .image : .file,
                thumbnailData: $0.thumbnailData,
                uploadID: $0.id
            )
        }
        MobileHapticFeedback().impact(style: .light)
        #else
        let outbound: [ChatOutboundAttachment] = []
        #endif
        onSend(trimmedDraft, outbound)
        draft = ""
        #if os(iOS)
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
        if attachments.count < MobileStagedAttachment.maximumCount,
           let pasted = pasteboard.chatComposerAttachment(
               maxDimension: Self.maxAttachmentDimension,
               jpegQuality: Self.jpegQuality
           ) {
            let fileName = pasted.format == .png ? "pasted-image.png" : "pasted-image.jpg"
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-pasted-\(UUID())-\(fileName)")
            do {
                try pasted.data.write(to: url, options: .atomic)
                startAttachmentStaging { generation in
                    defer { try? FileManager.default.removeItem(at: url) }
                    do {
                        let attachment = try await MobileAttachmentStager().stage(
                            sourceURL: url,
                            kind: .image,
                            originalFileName: fileName
                        )
                        guard !Task.isCancelled,
                              attachmentStagingGeneration == generation else {
                            try? FileManager.default.removeItem(at: attachment.localFileURL)
                            return
                        }
                        appendStagedAttachment(attachment)
                    } catch is CancellationError {
                        return
                    } catch {
                        guard attachmentStagingGeneration == generation else { return }
                        attachmentError = attachmentErrorMessage(error)
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                attachmentError = attachmentErrorMessage(error)
            }
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
        MobileAttachmentPickerButton(
            style: .circularPlus,
            isDisabled: isStagingAttachments || attachments.count >= MobileStagedAttachment.maximumCount,
            choosePhotos: { isPhotoPickerPresented = true },
            chooseFiles: { isFileImporterPresented = true }
        )
        .accessibilityIdentifier("ChatComposerAttach")
        .accessibilityLabel(
            String(
                localized: "chat.composer.attach.accessibility",
                defaultValue: "Add attachment",
                bundle: .module
            )
        )
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
        MobileAttachmentCardStrip(
            attachments: attachments,
            isDisabled: false,
            isPreparing: isStagingAttachments,
            onPreviewDismiss: { isDraftFocused = true },
            remove: removeAttachment
        )
    }

    private func removeAttachment(id: UUID) {
        guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }
        let removed = attachments.remove(at: index)
        try? FileManager.default.removeItem(at: removed.localFileURL)
    }

    private func startLoadingPickedItems(_ items: [PhotosPickerItem]) {
        startAttachmentStaging { generation in
            await loadPickedItems(items, generation: generation)
        }
    }

    private func startLoadingPickedFiles(_ result: Result<[URL], any Error>) {
        if case let .failure(error) = result,
           (error as? CocoaError)?.code == .userCancelled {
            return
        }
        if case let .success(urls) = result,
           urls.count > MobileStagedAttachment.maximumCount - attachments.count {
            attachmentError = String(
                localized: "mobile.attachment.error.count",
                defaultValue: "You can attach up to 10 files.",
                bundle: .module
            )
        }
        startAttachmentStaging { generation in
            await loadPickedFiles(result, generation: generation)
        }
    }

    private func startAttachmentStaging(
        operation: @escaping @MainActor (UUID) async -> Void
    ) {
        attachmentStagingTask?.cancel()
        let generation = UUID()
        attachmentStagingGeneration = generation
        isStagingAttachments = true
        attachmentStagingTask = Task { @MainActor in
            await operation(generation)
            guard attachmentStagingGeneration == generation else { return }
            attachmentStagingTask = nil
            isStagingAttachments = false
        }
    }

    private func loadPickedItems(_ items: [PhotosPickerItem], generation: UUID) async {
        for item in items.prefix(MobileStagedAttachment.maximumCount - attachments.count) {
            guard !Task.isCancelled, attachmentStagingGeneration == generation else { return }
            do {
                guard let imported = try await item.loadTransferable(type: MobileImportedImageFile.self) else { continue }
                defer { try? FileManager.default.removeItem(at: imported.url) }
                let attachment = try await MobileAttachmentStager().stage(
                    sourceURL: imported.url,
                    kind: .image,
                    originalFileName: imported.originalFileName
                )
                guard !Task.isCancelled, attachmentStagingGeneration == generation else {
                    try? FileManager.default.removeItem(at: attachment.localFileURL)
                    return
                }
                appendStagedAttachment(attachment)
            } catch is CancellationError {
                return
            } catch {
                guard attachmentStagingGeneration == generation else { return }
                attachmentError = attachmentErrorMessage(error)
            }
        }
    }

    private func loadPickedFiles(_ result: Result<[URL], any Error>, generation: UUID) async {
        guard case let .success(urls) = result else {
            attachmentError = attachmentErrorMessage(nil)
            return
        }
        for url in urls.prefix(MobileStagedAttachment.maximumCount - attachments.count) {
            guard !Task.isCancelled, attachmentStagingGeneration == generation else { return }
            do {
                let attachment = try await MobileAttachmentStager().stage(
                    sourceURL: url,
                    kind: .file,
                    originalFileName: url.lastPathComponent
                )
                guard !Task.isCancelled, attachmentStagingGeneration == generation else {
                    try? FileManager.default.removeItem(at: attachment.localFileURL)
                    return
                }
                appendStagedAttachment(attachment)
            } catch is CancellationError {
                return
            } catch {
                guard attachmentStagingGeneration == generation else { return }
                attachmentError = attachmentErrorMessage(error)
            }
        }
    }

    private func attachmentErrorMessage(_ error: (any Error)?) -> String {
        if let error,
           case MobileAttachmentStager.StagingError.fileTooLarge = error {
            return String(
                localized: "mobile.attachment.error.tooLarge",
                defaultValue: "Attachments must be 32 MB or smaller.",
                bundle: .module
            )
        }
        return String(
            localized: "mobile.attachment.error.unreadable",
            defaultValue: "The selected file couldn’t be read.",
            bundle: .module
        )
    }

    private func appendStagedAttachment(_ attachment: MobileStagedAttachment) {
        guard attachments.count < MobileStagedAttachment.maximumCount else {
            try? FileManager.default.removeItem(at: attachment.localFileURL)
            attachmentError = String(
                localized: "mobile.attachment.error.count",
                defaultValue: "You can attach up to 10 files.",
                bundle: .module
            )
            return
        }
        let total = attachments.reduce(0) { $0 + $1.byteCount }
        guard total + attachment.byteCount <= MobileStagedAttachment.maximumTotalBytes else {
            try? FileManager.default.removeItem(at: attachment.localFileURL)
            attachmentError = String(
                localized: "mobile.attachment.error.total",
                defaultValue: "Attachments can use up to 64 MB in total.",
                bundle: .module
            )
            return
        }
        attachments.append(attachment)
    }

    private func removeUnsentAttachments() {
        let unsent = attachments
        attachments = []
        for attachment in unsent {
            try? FileManager.default.removeItem(at: attachment.localFileURL)
        }
    }
    #endif
}
