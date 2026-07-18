#if DEBUG
import SwiftUI

/// Renders the shared Approve and Deny action row used across Signal screens.
struct SignalActionButtons: View {
    let theme: SignalTheme

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(DesignGalleryFixtures.approvalActions.enumerated()), id: \.offset) { index, title in
                Button(action: {}) {
                    Text(title)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SignalPressButtonStyle(
                    role: index == 0 ? .primary : .secondary,
                    theme: theme
                ))
            }
        }
    }
}
#endif
