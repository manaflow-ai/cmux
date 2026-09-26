#if os(iOS)
public import SwiftUI

/// The Cloud tab's content, supplied by the composition root.
///
/// The shell deliberately does not depend on the Cloud packages: Cloud
/// machines already reach the workspace experience as ordinary hosts, so the
/// only thing the shell needs from Cloud is a view to mount in its tab. A
/// build with no Cloud service configured supplies nothing, and the tab is
/// omitted.
public struct MobileCloudTabContent: Sendable {
    private let content: @MainActor @Sendable () -> AnyView

    /// Wraps the view the Cloud tab shows.
    public init(@ViewBuilder content: @escaping @MainActor @Sendable () -> some View) {
        self.content = { AnyView(content()) }
    }

    /// Builds the tab's view.
    @MainActor
    public func makeView() -> AnyView { content() }
}

extension EnvironmentValues {
    /// The Cloud tab's content, or `nil` when this build has no Cloud.
    @Entry public var mobileCloudTabContent: MobileCloudTabContent?
}
#endif
