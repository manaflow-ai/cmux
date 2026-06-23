import CmuxMobileSupport
import SwiftUI

struct RestoringSessionView: View {
    let retry: () -> Void
    let signOut: () -> Void
    let showAddDevice: (() -> Void)?
    var timeoutSeconds: TimeInterval = 12

    @State private var didTimeout = false
    @State private var timeoutTimer: Timer?

    var body: some View {
        NavigationStack {
            ZStack {
                GameOfLifeHeader()
                    .ignoresSafeArea()

                VStack(spacing: 16) {
                    Image("CmuxLogo")
                        .resizable()
                        .renderingMode(.original)
                        .scaledToFit()
                        .frame(width: 30, height: 30)
                        .accessibilityHidden(true)

                    if didTimeout {
                        Text(L10n.string("mobile.signIn.restoreTimeout.title", defaultValue: "Could not restore session"))
                            .font(.headline)
                        Text(L10n.string("mobile.signIn.restoreTimeout.body", defaultValue: "Check that your Mac is awake and on the same account, then retry."))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 320)
                        HStack(spacing: 10) {
                            Button(L10n.string("mobile.recovery.retry", defaultValue: "Retry")) {
                                didTimeout = false
                                retry()
                                scheduleTimeout()
                            }
                            .buttonStyle(.borderedProminent)

                            Button(L10n.string("mobile.signIn.again", defaultValue: "Sign in again")) {
                                signOut()
                            }
                            .buttonStyle(.bordered)
                        }
                        if let showAddDevice {
                            Button(L10n.string("mobile.addDevice.title", defaultValue: "Add device")) {
                                showAddDevice()
                            }
                            .buttonStyle(.bordered)
                        }
                    } else {
                        ProgressView(L10n.string("mobile.signIn.restoring", defaultValue: "Restoring session"))
                            .controlSize(.regular)
                    }
                }
                .foregroundStyle(.primary)
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("MobileRestoringSessionView")
            }
            .mobileInlineNavigationTitle()
        }
        .onAppear {
            scheduleTimeout()
        }
        .onDisappear {
            timeoutTimer?.invalidate()
            timeoutTimer = nil
        }
    }

    @MainActor
    private func scheduleTimeout() {
        timeoutTimer?.invalidate()
        timeoutTimer = Timer.scheduledTimer(withTimeInterval: timeoutSeconds, repeats: false) { _ in
            MainActor.assumeIsolated {
                didTimeout = true
            }
        }
    }
}
