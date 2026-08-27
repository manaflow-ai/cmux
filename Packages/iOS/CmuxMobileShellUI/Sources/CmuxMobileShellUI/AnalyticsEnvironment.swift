import CMUXMobileCore
import SwiftUI

/// Carries the injected ``CMUXMobileCore/AnalyticsEmitting`` down the SwiftUI
/// view tree so views fire product events through the same emitter the shell
/// store and app delegate use, without reaching for a singleton.
///
/// The root scene injects the app-root emitter with `.analytics(...)`; views read
/// it via `@Environment(\.analytics)`. The default is ``CMUXMobileCore/NoopAnalytics``
/// so previews and any unwired subtree drop events harmlessly.
private struct AnalyticsEnvironmentKey: EnvironmentKey {
    static let defaultValue: any AnalyticsEmitting = NoopAnalytics()
}

extension EnvironmentValues {
    /// The product-analytics emitter for the current view subtree.
    public var analytics: any AnalyticsEmitting {
        get { self[AnalyticsEnvironmentKey.self] }
        set { self[AnalyticsEnvironmentKey.self] = newValue }
    }
}

extension View {
    /// Injects the analytics emitter into the environment of this view subtree.
    /// - Parameter analytics: The emitter to inject.
    /// - Returns: A view whose descendants read `@Environment(\.analytics)`.
    public func analytics(_ analytics: any AnalyticsEmitting) -> some View {
        environment(\.analytics, analytics)
    }
}
