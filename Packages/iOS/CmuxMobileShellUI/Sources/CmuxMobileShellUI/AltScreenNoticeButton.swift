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
            popoverContent
                .presentationCompactAdaptation(.popover)
        }
    }

    private var popoverContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.orange)

            Text(explanation)
                .font(.footnote)
                .foregroundStyle(.secondary)

            Button(action: dismissFromPopover) {
                Text(dismissActionTitle)
            }
            .font(.footnote.weight(.medium))
        }
        .padding(16)
        .frame(maxWidth: 320, alignment: .leading)
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
            defaultValue: "A full-screen terminal app is running in this session. Full-screen apps mirror the Mac terminal's exact size, so the view may not fill this screen."
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
