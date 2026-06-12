import CmuxAgentChat
import SwiftUI

#if os(iOS)
import PhotosUI
import UIKit
#endif

/// The keyboard-attached bottom bar: accessory chips, the staged-attachment
/// strip (iOS), the multiline draft field, and the context-aware send/stop
/// button.
public struct ChatComposerView: View {
    private let agentState: ChatAgentState
    private let agentKind: ChatAgentKind
    private let isConnected: Bool
    private let onSend: (String, [ChatOutboundAttachment]) -> Void
    private let onInterrupt: (Bool) -> Void
    private let onOpenTerminal: () -> Void

    @Binding private var draft: String
    @State private var lastStopTap: Date?
    #if os(iOS)
    @State private var pickedItems: [PhotosPickerItem] = []
    @State private var attachments: [ChatComposerAttachment] = []
    #endif

    @Environment(\.chatTheme) private var theme

    private static let maxAttachmentDimension: CGFloat = 2048
    private static let jpegQuality: CGFloat = 0.85
    private static let hardStopWindow: TimeInterval = 2

    /// Creates the composer.
    ///
    /// - Parameters:
    ///   - agentState: Live agent presence; working turns the empty-draft
    ///     send button into a stop button.
    ///   - agentKind: The session's agent, for the field placeholder.
    ///   - isConnected: Whether the live event stream is up.
    ///   - onSend: Sends the draft and staged attachments.
    ///   - onInterrupt: Interrupts the agent (`false` = Esc, `true` =
    ///     Ctrl-C).
    ///   - onOpenTerminal: Opens the session's raw terminal.
    public init(
        agentState: ChatAgentState,
        agentKind: ChatAgentKind,
        isConnected: Bool,
        draft: Binding<String>,
        onSend: @escaping (String, [ChatOutboundAttachment]) -> Void,
        onInterrupt: @escaping (Bool) -> Void,
        onOpenTerminal: @escaping () -> Void
    ) {
        self.agentState = agentState
        self.agentKind = agentKind
        self.isConnected = isConnected
        _draft = draft
        self.onSend = onSend
        self.onInterrupt = onInterrupt
        self.onOpenTerminal = onOpenTerminal
    }

    public var body: some View {
        VStack(spacing: 8) {
            if isEnded {
                endedRow
            } else {
                ChatAccessoryChipRow(
                    agentState: agentState,
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
        .padding(.horizontal, theme.horizontalMargin)
        .padding(.vertical, 8)
        .background(.thinMaterial)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(theme.hairline)
                .frame(height: 0.5)
        }
    }

    // MARK: - Field row

    private var fieldRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            #if os(iOS)
            attachButton
            #endif
            TextField(placeholder, text: $draft, axis: .vertical)
                .lineLimit(1...6)
                .font(.body)
                .textFieldStyle(.plain)
                .accessibilityIdentifier("ChatComposerField")
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    Color.secondary.opacity(0.15),
                    in: .rect(cornerRadius: 18)
                )
            sendButton
        }
    }

    private var placeholder: String {
        String(
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

    /// Replaces the input row when the session can no longer accept input;
    /// the terminal escape hatch stays reachable.
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
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(isConnected ? theme.accent : Color.secondary)
                    .frame(width: 36, height: 36)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .disabled(!isConnected)
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
                .frame(width: 32, height: 32)
                .frame(width: 36, height: 36)
                .contentShape(.circle)
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
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
                .opacity(0.4)
                .frame(width: 36, height: 36)
        }
    }

    private func performSend() {
        guard hasContent else { return }
        #if os(iOS)
        let outbound = attachments.map(\.outbound)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
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

    /// First tap interrupts politely; a second tap within the window
    /// escalates to a hard interrupt (Ctrl-C).
    private func performStop() {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
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
    private var attachButton: some View {
        PhotosPicker(selection: $pickedItems, maxSelectionCount: 4, matching: .images) {
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 36, height: 36)
                .background(Color.secondary.opacity(0.15), in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            String(
                localized: "chat.composer.attach.accessibility",
                defaultValue: "Add attachment",
                bundle: .module
            )
        )
        .onChange(of: pickedItems) {
            let items = pickedItems
            Task { await loadPickedItems(items) }
        }
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    attachment.thumbnail
                        .resizable()
                        .scaledToFill()
                        .frame(width: 60, height: 60)
                        .clipShape(.rect(cornerRadius: 10))
                        .overlay(alignment: .topTrailing) {
                            removeButton(id: attachment.id)
                        }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func removeButton(id: String) -> some View {
        Button {
            removeAttachment(id: id)
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(.white, .black.opacity(0.6))
                .padding(3)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            String(
                localized: "chat.composer.remove_attachment.accessibility",
                defaultValue: "Remove attachment",
                bundle: .module
            )
        )
    }

    private func removeAttachment(id: String) {
        guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }
        attachments.remove(at: index)
        if pickedItems.indices.contains(index) {
            pickedItems.remove(at: index)
        }
    }

    /// Loads the picker selection into staged attachments: each item is
    /// decoded, downscaled to the size cap, and re-encoded as JPEG.
    private func loadPickedItems(_ items: [PhotosPickerItem]) async {
        var staged: [ChatComposerAttachment] = []
        for (index, item) in items.enumerated() {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let jpeg = Self.downscaledJPEG(from: data),
                  let thumbnailImage = UIImage(data: jpeg)
            else { continue }
            staged.append(
                ChatComposerAttachment(
                    id: item.itemIdentifier ?? "picked-\(index)",
                    data: jpeg,
                    format: .jpeg,
                    thumbnail: Image(uiImage: thumbnailImage)
                )
            )
        }
        attachments = staged
    }

    /// Re-encodes image data as JPEG, downscaling so the longest side is at
    /// most ``maxAttachmentDimension`` points.
    private static func downscaledJPEG(from data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        let longest = max(pixelWidth, pixelHeight)
        guard longest > maxAttachmentDimension else {
            return image.jpegData(compressionQuality: jpegQuality)
        }
        let scale = maxAttachmentDimension / longest
        let targetSize = CGSize(width: pixelWidth * scale, height: pixelHeight * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        return resized.jpegData(compressionQuality: jpegQuality)
    }
    #endif
}
