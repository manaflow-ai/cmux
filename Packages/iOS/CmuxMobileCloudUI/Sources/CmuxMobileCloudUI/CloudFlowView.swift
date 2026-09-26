#if os(iOS)
public import CmuxMobileCloud
import CmuxMobileSupport
public import SwiftUI

/// The Cloud tab's navigation stack: the account's machines and their
/// management.
///
/// Terminals are deliberately NOT reached from here. A Cloud machine's
/// workspaces appear in the Workspaces tab alongside every other computer's,
/// and open into the same detail screen, toolbar, terminal and composer, so
/// the terminal experience is identical whichever computer serves it. This
/// tab is where machines are created, inspected and retired.
///
/// The authenticated shell owns the connection lifetime, so changing tabs
/// preserves both this stack's path and its live connections.
public struct CloudFlowView: View {
    private let controller: CloudSessionController
    @State private var path = NavigationPath()
    @AppStorage("mobile.cloud.onboarding.completed.v2") private var cloudOnboardingCompleted = false
    @State private var showsCloudOnboarding = false

    /// Creates the flow over the app's session controller.
    public init(controller: CloudSessionController) {
        self.controller = controller
    }

    public var body: some View {
        NavigationStack(path: $path) {
            Group {
                if cloudOnboardingCompleted {
                    CloudSectionView(controller: controller)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button(L10n.string("mobile.cloud.onboarding.title", defaultValue: "Cloud basics")) {
                                    showsCloudOnboarding = true
                                }
                                .accessibilityIdentifier("CloudBasicsButton")
                            }
                        }
                } else {
                    CloudOnboardingView(
                        controller: controller,
                        onComplete: { cloudOnboardingCompleted = true },
                        showsNavigationChrome: false
                    )
                    .accessibilityIdentifier("CloudInlineOnboarding")
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button(L10n.string("mobile.cloud.onboarding.skip", defaultValue: "Skip")) {
                                cloudOnboardingCompleted = true
                            }
                            .accessibilityIdentifier("CloudInlineOnboardingSkip")
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showsCloudOnboarding) {
            CloudOnboardingView(controller: controller)
        }
    }
}
#endif
