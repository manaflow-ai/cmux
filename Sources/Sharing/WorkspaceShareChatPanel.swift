import AppKit
import Combine
import SwiftUI

@MainActor
final class WorkspaceShareChatPanel: Panel, ObservableObject {
    let id = UUID()
    let stableSurfaceIdentity = PanelStableSurfaceIdentity()
    let panelType: PanelType = .workspaceShareChat
    let model: WorkspaceShareChatModel

    @Published private(set) var focusGeneration = 0

    init(model: WorkspaceShareChatModel) {
        self.model = model
    }

    var displayTitle: String {
        String(localized: "workspaceShare.chat.title", defaultValue: "Workspace chat")
    }

    var displayIcon: String? { "bubble.left.and.bubble.right.fill" }

    func close() {}

    func focus() {
        focusGeneration &+= 1
    }

    func unfocus() {}

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
    }
}

struct WorkspaceShareChatPanelView: View {
    @ObservedObject var panel: WorkspaceShareChatPanel
    @Bindable private var model: WorkspaceShareChatModel
    let appearance: PanelAppearance
    let onRequestPanelFocus: () -> Void

    @State private var draft = ""
    @State private var linkCopied = false
    @FocusState private var draftFocused: Bool

    init(
        panel: WorkspaceShareChatPanel,
        appearance: PanelAppearance,
        onRequestPanelFocus: @escaping () -> Void
    ) {
        self.panel = panel
        _model = Bindable(wrappedValue: panel.model)
        self.appearance = appearance
        self.onRequestPanelFocus = onRequestPanelFocus
    }

    var body: some View {
        VStack(spacing: 0) {
            sharingHeader
            Divider()
            if !model.pendingAccess.isEmpty {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(model.pendingAccess) { pending in
                            accessCard(pending)
                        }
                    }
                    .padding(10)
                }
                .frame(maxHeight: 230)
                Divider()
            }
            transcript
            Divider()
            composer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: appearance.backgroundColor))
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { onRequestPanelFocus() })
        .onAppear { draftFocused = true }
        .onChange(of: panel.focusGeneration) { _, _ in draftFocused = true }
    }

    private var sharingHeader: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 7, height: 7)
                Text(String(localized: "workspaceShare.ready.title", defaultValue: "Workspace sharing is live"))
                    .font(.system(size: 11, weight: .semibold))
                Spacer(minLength: 8)
                Button(action: copyLink) {
                    Label(
                        linkCopied
                            ? String(localized: "workspaceShare.ready.copied", defaultValue: "Copied")
                            : String(localized: "workspaceShare.ready.copy", defaultValue: "Copy Link"),
                        systemImage: linkCopied ? "checkmark" : "link"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button(
                    String(localized: "workspaceShare.ready.stop", defaultValue: "Stop Sharing"),
                    role: .destructive,
                    action: model.stopSharing
                )
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            Text(model.shareURL.absoluteString)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
    }

    private var transcript: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 10) {
                if model.messages.isEmpty {
                    Text(String(
                        localized: "workspaceShare.chat.empty",
                        defaultValue: "Share the link to invite someone."
                    ))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 18)
                } else {
                    ForEach(model.messages, id: \.id) { message in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(message.displayName)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(WorkspaceShareParticipantColor.color(index: message.color))
                            Text(message.text)
                                .font(.system(size: 11))
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var composer: some View {
        HStack(spacing: 7) {
            TextField(
                String(localized: "workspaceShare.chat.placeholder", defaultValue: "Message everyone"),
                text: $draft
            )
            .textFieldStyle(.plain)
            .font(.system(size: 11))
            .focused($draftFocused)
            .onSubmit(send)

            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help(String(localized: "workspaceShare.chat.send", defaultValue: "Send"))
        }
        .padding(8)
    }

    private func accessCard(_ pending: WorkspaceSharePendingAccess) -> some View {
        let request = pending.request
        let titleFormat = String(
            localized: "workspaceShare.access.wantsAccess",
            defaultValue: "%@ wants access"
        )
        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .foregroundStyle(WorkspaceShareParticipantColor.color(index: request.color))
                Text(String(format: titleFormat, request.email))
                    .font(.system(size: 12, weight: .semibold))
                    .textSelection(.enabled)
            }
            Text(request.displayName)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text(String(
                localized: "workspaceShare.access.scope",
                defaultValue: "Allowing access lets this person view the full workspace and type or run commands in every shared terminal."
            ))
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            if pending.state == .failed {
                Text(String(
                    localized: "workspaceShare.access.failed",
                    defaultValue: "Couldn’t send the decision. Try again."
                ))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.red)
            }
            HStack(spacing: 7) {
                Button(String(localized: "workspaceShare.access.deny", defaultValue: "Deny")) {
                    model.decide(userID: request.userId, as: .deny)
                }
                Button(String(localized: "workspaceShare.access.allow", defaultValue: "Allow")) {
                    model.decide(userID: request.userId, as: .allow)
                }
                .buttonStyle(.borderedProminent)
                if pending.state == .sending {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .controlSize(.small)
            .disabled(pending.state == .sending)
        }
        .padding(10)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        model.sendChat(String(text.prefix(500)))
        draft = ""
    }

    private func copyLink() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.shareURL.absoluteString, forType: .string)
        linkCopied = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            linkCopied = false
        }
    }
}

enum WorkspaceShareParticipantColor {
    static func color(index: Int) -> Color {
        let palette: [Color] = [
            Color(red: 1, green: 0.36, blue: 0.48),
            Color(red: 0.31, green: 0.89, blue: 0.76),
            Color(red: 0.49, green: 0.55, blue: 1),
            Color(red: 1, green: 0.74, blue: 0.29),
            Color(red: 0.83, green: 0.47, blue: 1),
            Color(red: 0.33, green: 0.72, blue: 1),
            Color(red: 1, green: 0.5, blue: 0.31),
            Color(red: 0.41, green: 0.83, blue: 0.43),
            Color(red: 0.97, green: 0.42, blue: 0.83),
            Color(red: 0.19, green: 0.84, blue: 0.93),
            Color(red: 0.84, green: 0.85, blue: 0.3),
            Color(red: 0.67, green: 0.57, blue: 1),
        ]
        return palette[Int(index.magnitude % UInt(palette.count))]
    }
}
