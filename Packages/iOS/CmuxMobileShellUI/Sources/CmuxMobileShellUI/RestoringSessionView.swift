import CmuxMobileSupport
import SwiftUI

struct RestoringSessionView: View {
    var body: some View {
        NavigationStack {
            ZStack {
                GameOfLifeHeader()
                    .ignoresSafeArea()

                VStack(spacing: 14) {
                    Image("CmuxLogo")
                        .resizable()
                        .renderingMode(.original)
                        .scaledToFit()
                        .frame(width: 30, height: 30)
                        .accessibilityHidden(true)

                    ProgressView(L10n.string("mobile.signIn.restoring", defaultValue: "Restoring session"))
                        .controlSize(.regular)
                }
                .font(.headline)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("MobileRestoringSessionView")
            }
            .mobileInlineNavigationTitle()
        }
    }
}
