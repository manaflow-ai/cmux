#if DEBUG && os(iOS)
import CmuxMobileDesign
import SwiftUI

/// The one state a chat shows about its link: a message the Mac never took within
/// ``AgentChatStore/sendDeadline`` (Leo, 2026-11-22: "Show nothing unless a send has truly failed
/// after a long deadline. Even then show one quiet, themed, inline state, never a toast").
/// `-cmux-mobile-recovery-gallery notsent`: A, the row ``NotSentLine`` draws (picked), then the
/// variants it was picked from.
/// - A (picked): one footnote line under the bubble, secondary text, the whole line the tap target.
///   It reads like a timestamp, keeps the bubble as sent, and adds no colour.
/// - B: a small circled exclamation beside the bubble, the line only on tap. Quieter still, but a
///   bare glyph says nothing until tapped, and it is easy to miss that the Mac never got it.
/// - C: the bubble dimmed with an accent "Send Again" capsule under it. Clear, but it reads as an
///   alert: a button-weight control for a state Leo asked to keep quiet.
public struct NotSentGallery: View {
    public init() {}

    private let earlier = "Run the iOS kit tests on the fleet."
    private let unsent = "Then open the PR and queue it to land."

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                label("A · picked · footnote line")
                chat {
                    bubble(unsent)
                    Text(String(localized: "mobile.agentChat.notSent", defaultValue: "Not sent · Tap to send again", bundle: .module))
                        .font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .accessibilityIdentifier("notSentGallery.a")
                }
                label("B · glyph beside the bubble")
                chat {
                    HStack(alignment: .center, spacing: 8) {
                        Spacer(minLength: 40)
                        Image(systemName: "exclamationmark.circle")
                            .font(.footnote).foregroundStyle(.secondary)
                        bubble(unsent, aligned: false)
                    }
                }
                label("C · dimmed bubble, Send Again capsule")
                chat {
                    bubble(unsent).opacity(0.55)
                    Button("Send Again") {}
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.cmuxMobileAccent)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .glassEffect(.regular, in: .capsule)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .padding(.vertical, 60)
        }
        .accessibilityIdentifier("recoveryGallery.notsent.variants")
    }

    private func chat(@ViewBuilder _ last: () -> some View) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            bubble(earlier)
            Text("Started the run. 412 tests passed.")
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 8)
            last()
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func bubble(_ text: String, aligned: Bool = true) -> some View {
        let shape = Text(text)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .foregroundStyle(Color.cmuxMobileChatBubbleText.map(AnyShapeStyle.init) ?? AnyShapeStyle(.primary))
            .background(Color.cmuxMobileChatBubble, in: .rect(cornerRadius: 20, style: .continuous))
        if aligned {
            shape.frame(maxWidth: .infinity, alignment: .trailing).padding(.leading, 40)
        } else {
            shape
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20)
    }
}
#endif
