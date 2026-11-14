#if DEBUG && os(iOS)
import CmuxMobileDesign
import SwiftUI

/// The gallery of Toggle Terminal and Chat's control on the phone (`-cmux-mobile-recovery-gallery
/// terminalchat`, with `-cmux-mobile-gallery-appearance light|dark`), from design/terminal-chat-toggle.md
/// (the Mac's `>_ | bubble` control, two faces, the current one lit, one place on both faces) and the
/// iOS spec's glass circle buttons outside toolbars (cmux-next-ios/design/SPEC.md):
/// - A (picked): one glass capsule of two icon segments, the lit face on a fill. The Mac's control, at
///   a phone's touch size; one hit target per face.
/// - B: two separate glass circles. Reads as two unrelated tools, not one switch with two states.
/// - C: a text segmented control ("Chat | Terminal"). Clearest words, but twice as wide over the
///   chat's first row and the terminal's top line, and unlike the Mac's icons.
/// Each on the chat face and the terminal face, and A with the other face disabled (a chat no terminal
/// runs, a terminal whose chat the Mac has not opened).
public struct TerminalChatToggleGallery: View {
    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                row("A (picked): one glass capsule") {
                    TerminalChatToggleControl(showsChat: true) { _ in }
                    TerminalChatToggleControl(showsChat: false) { _ in }
                }
                row("A: the other face disabled") {
                    TerminalChatToggleControl(showsChat: true, terminalEnabled: false) { _ in }
                    TerminalChatToggleControl(showsChat: false, chatEnabled: false) { _ in }
                }
                row("B: two glass circles") {
                    circles(chat: true)
                    circles(chat: false)
                }
                row("C: text segments") {
                    words(chat: true)
                    words(chat: false)
                }
            }
            .padding(20)
        }
        .background(CmuxMobileTheme.standard.colors.bg.color)
        .accessibilityIdentifier("terminalChatToggleGallery")
    }

    private func row(_ title: String, @ViewBuilder _ faces: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.footnote).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                faces()
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .background(pageBackdrop, in: .rect(cornerRadius: 14))
        }
    }

    /// What the control floats over: a chat's first row and a terminal's top line.
    private var pageBackdrop: some ShapeStyle {
        LinearGradient(colors: [Color.black.opacity(0.85), CmuxMobileTheme.standard.colors.bg.color], startPoint: .leading, endPoint: .trailing)
    }

    private func circles(chat: Bool) -> some View {
        HStack(spacing: 8) {
            ForEach([true, false], id: \.self) { face in
                Image(systemName: face ? "bubble.left" : "terminal")
                    .font(.body.weight(face == chat ? .semibold : .regular))
                    .foregroundStyle(face == chat ? Color.primary : Color.secondary)
                    .frame(width: 36, height: 36)
                    .glassEffect(.regular.interactive(), in: .circle)
            }
        }
    }

    private func words(chat: Bool) -> some View {
        HStack(spacing: 2) {
            ForEach([true, false], id: \.self) { face in
                Text(face ? "Chat" : "Terminal")
                    .font(.subheadline.weight(face == chat ? .semibold : .regular))
                    .foregroundStyle(face == chat ? Color.primary : Color.secondary)
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(face == chat ? Color.primary.opacity(0.12) : .clear, in: .capsule)
            }
        }
        .padding(3)
        .glassEffect(.regular, in: .capsule)
    }
}
#endif
