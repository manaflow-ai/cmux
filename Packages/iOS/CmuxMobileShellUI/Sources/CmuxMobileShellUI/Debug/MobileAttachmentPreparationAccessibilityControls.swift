#if os(iOS) && DEBUG
import CmuxMobileSupport
import SwiftUI

/// Manual late-completion controls exposed only by DEBUG accessibility hosts.
struct MobileAttachmentPreparationAccessibilityControls: View {
    let fixture: MobileAttachmentPreparationAccessibilityFixture

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Button {
                fixture.complete()
            } label: {
                Image(systemName: "checkmark.circle")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.string(
                "mobile.attachment.debug.completePreparation",
                defaultValue: "Complete attachment preparation"
            ))
            .accessibilityIdentifier("MobileAttachmentPreparationFixtureComplete")

            if fixture.didReturn {
                Text(verbatim: "returned")
                    .accessibilityIdentifier("MobileAttachmentPreparationFixtureReturned")
            }
        }
    }
}
#endif
