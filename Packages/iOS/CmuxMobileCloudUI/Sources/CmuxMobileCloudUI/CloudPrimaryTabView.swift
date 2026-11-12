#if os(iOS)
import CmuxMobileCloud
import CmuxMobileSupport
public import SwiftUI

/// The Cloud destination in the app's primary navigation. Its stack stays
/// mounted independently of the Mac connection and other tabs' navigation.
public struct CloudPrimaryTabView: View {
    @Environment(\.cloudSessionController) private var controller
    private let embedsNavigationStack: Bool

    /// Creates the primary destination using the scene's Cloud controller.
    /// - Parameter embedsNavigationStack: False inside a navigation container
    ///   the shell already owns, such as the iPad sidebar.
    public init(embedsNavigationStack: Bool = true) {
        self.embedsNavigationStack = embedsNavigationStack
    }

    public var body: some View {
        if let controller {
            CloudFlowView(controller: controller, embedsNavigationStack: embedsNavigationStack)
        } else {
            ContentUnavailableView(
                L10n.string("mobile.cloud.notConfigured.title", defaultValue: "Cloud unavailable"),
                systemImage: "cloud",
                description: Text(L10n.string(
                    "mobile.cloud.notConfigured.body",
                    defaultValue: "Cloud is not configured in this build."
                ))
            )
        }
    }
}

extension View {
    /// Keeps the Cloud connection alive while the authenticated shell is
    /// visible, including when another tab covers the Cloud navigation stack.
    public func cloudSessionLifetime() -> some View {
        modifier(CloudSessionLifetime())
    }
}

private struct CloudSessionLifetime: ViewModifier {
    @Environment(\.cloudSessionController) private var controller
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onAppear {
                if scenePhase == .background { controller?.sceneDidEnterBackground() }
                else { controller?.sceneWillEnterForeground() }
                controller?.sectionDidAppear()
            }
            .onDisappear { controller?.sectionDidDisappear() }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active: controller?.sceneWillEnterForeground()
                case .background: controller?.sceneDidEnterBackground()
                default: break
                }
            }
    }
}
#endif
