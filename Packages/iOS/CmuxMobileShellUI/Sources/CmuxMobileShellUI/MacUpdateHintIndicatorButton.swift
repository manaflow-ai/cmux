import CmuxMobileShell
import CmuxMobileSupport
import SwiftUI

struct MacUpdateHintIndicatorButton: View {
    let hint: MobileMacUpdateHint
    let macDisplayName: String?
    let dismiss: () -> Void
    @State private var isPresentingExplanation = false

    var body: some View {
        Button {
            isPresentingExplanation = true
        } label: {
            Label(buttonAccessibilityLabel, systemImage: "arrow.up.circle.fill")
        }
        .labelStyle(.iconOnly)
        .foregroundStyle(.teal)
        .accessibilityLabel(buttonAccessibilityLabel)
        .accessibilityIdentifier("MobileMacUpdateHintIndicatorButton")
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
                Image(systemName: "arrow.up.circle.fill")
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.teal)

            Text(MobileMacUpdateFeatureDisplay.bodyText(hint: hint, macName: macDisplayName))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: dismissFromPopover) {
                Text(dismissActionTitle)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.footnote.weight(.medium))
            .accessibilityIdentifier("MobileMacUpdateHintDismissButton")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .multilineTextAlignment(.leading)
    }

    private var buttonAccessibilityLabel: String {
        L10n.string(
            "mobile.macUpdateHint.button.accessibilityLabel",
            defaultValue: "Show what a Mac update adds"
        )
    }

    private var title: String {
        L10n.string(
            "mobile.macUpdateHint.title",
            defaultValue: "Mac update adds features"
        )
    }

    private var dismissActionTitle: String {
        L10n.string(
            "mobile.macUpdateHint.dismiss",
            defaultValue: "Don't show again for this version"
        )
    }

    private func dismissFromPopover() {
        dismiss()
        isPresentingExplanation = false
    }
}
