import CmuxMobileSupport
import SwiftUI

struct AltScreenNoticeButton: View {
    let dismissNotice: () -> Void
    @State private var isPresentingExplanation = false

    var body: some View {
        Button {
            isPresentingExplanation = true
        } label: {
            Label(buttonAccessibilityLabel, systemImage: "exclamationmark.triangle.fill")
        }
        .labelStyle(.iconOnly)
        .foregroundStyle(.orange)
        .accessibilityLabel(buttonAccessibilityLabel)
        .accessibilityIdentifier("MobileTerminalAltScreenNoticeButton")
        .popover(isPresented: $isPresentingExplanation) {
            ViewThatFits(in: .vertical) {
                popoverContent

                ScrollView {
                    popoverContent
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .frame(
                idealWidth: AltScreenNoticePresentationSizing.maxWidth,
                maxWidth: AltScreenNoticePresentationSizing.maxWidth
            )
            .presentationSizing(AltScreenNoticePresentationSizing())
            .presentationCompactAdaptation(.popover)
        }
    }

    private var popoverContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text(title)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.orange)

            Text(explanation)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: dismissFromPopover) {
                Text(dismissActionTitle)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.footnote.weight(.medium))
            .accessibilityIdentifier("MobileTerminalAltScreenNoticeDismissPermanentlyButton")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .multilineTextAlignment(.leading)
    }

    private var buttonAccessibilityLabel: String {
        L10n.string(
            "mobile.altScreenNotice.button.accessibilityLabel",
            defaultValue: "Explain full-screen terminal sizing"
        )
    }

    private var title: String {
        L10n.string(
            "mobile.altScreenNotice.title",
            defaultValue: "Full-screen terminal app"
        )
    }

    private var explanation: String {
        L10n.string(
            "mobile.altScreenNotice.explanation",
            defaultValue: "Full-screen mode mirrors the Mac terminal's exact size, so it may not fill this screen. Claude Code: `/tui default`. Codex: restart with `codex --no-alt-screen`."
        )
    }

    private var dismissActionTitle: String {
        L10n.string(
            "mobile.altScreenNotice.dismissAction",
            defaultValue: "Don't Show Again"
        )
    }

    private func dismissFromPopover() {
        dismissNotice()
        isPresentingExplanation = false
    }
}
