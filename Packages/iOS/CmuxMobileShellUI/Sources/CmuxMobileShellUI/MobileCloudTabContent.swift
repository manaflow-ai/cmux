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
    private let embedded: @MainActor @Sendable () -> AnyView

    /// Wraps the views Cloud shows.
    /// - Parameters:
    ///   - content: The phone tab's view, which owns its navigation stack.
    ///   - embedded: The same screen for a navigation container the shell
    ///     already owns (the iPad sidebar), so the shell's own bars stay.
    public init(
        @ViewBuilder content: @escaping @MainActor @Sendable () -> some View,
        @ViewBuilder embedded: @escaping @MainActor @Sendable () -> some View
    ) {
        self.content = { AnyView(content()) }
        self.embedded = { AnyView(embedded()) }
    }

    /// Builds the tab's view.
    @MainActor
    public func makeView() -> AnyView { content() }

    /// Builds the view for a navigation container the shell owns.
    @MainActor
    public func makeEmbeddedView() -> AnyView { embedded() }
}

extension EnvironmentValues {
    /// The Cloud tab's content, or `nil` when this build has no Cloud.
    @Entry public var mobileCloudTabContent: MobileCloudTabContent?
}
#endif
