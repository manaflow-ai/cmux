import CmuxMobileSupport
import SwiftUI

struct RestoringSessionView: View {
    var onRetry: (() -> Void)?
    var onSignInAgain: (() -> Void)?

    @State private var startedAt = Date()

    private let recoveryDelay: TimeInterval = 10

    var body: some View {
        NavigationStack {
            ZStack {
                GameOfLifeHeader()
                    .ignoresSafeArea()

                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    content(showsRecovery: context.date.timeIntervalSince(startedAt) >= recoveryDelay)
                }
            }
            .mobileInlineNavigationTitle()
        }
        .onAppear {
            startedAt = Date()
        }
    }

    @ViewBuilder
    private func content(showsRecovery: Bool) -> some View {
        VStack(spacing: 14) {
            Image("CmuxLogo")
                .resizable()
                .renderingMode(.original)
                .scaledToFit()
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)

            ProgressView(L10n.string("mobile.signIn.restoring", defaultValue: "Restoring session"))
                .controlSize(.regular)

            if showsRecovery, (onRetry != nil || onSignInAgain != nil) {
                VStack(spacing: 10) {
                    Text(L10n.string(
                        "mobile.signIn.restoringSlow",
                        defaultValue: "This is taking longer than expected."
                    ))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                    if let onRetry {
                        Button {
                            onRetry()
                        } label: {
                            Text(L10n.string("mobile.signIn.restoreRetry", defaultValue: "Retry"))
                                .fontWeight(.semibold)
                        }
                        .mobileGlassButton()
                        .accessibilityIdentifier("MobileRestoringSessionRetry")
                    }

                    if let onSignInAgain {
                        Button {
                            onSignInAgain()
                        } label: {
                            Text(L10n.string(
                                "mobile.signIn.restoreSignInAgain",
                                defaultValue: "Sign in again"
                            ))
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("MobileRestoringSessionSignInAgain")
                    }
                }
                .transition(.opacity)
            }
        }
        .font(.headline)
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("MobileRestoringSessionView")
    }
}
