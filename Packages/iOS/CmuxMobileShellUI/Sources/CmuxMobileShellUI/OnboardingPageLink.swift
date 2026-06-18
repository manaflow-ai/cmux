#if os(iOS)
import Foundation

/// An optional inline link shown below an ``OnboardingPage`` body (used by the
/// Tailscale page to point at the install page).
struct OnboardingPageLink: Sendable {
    let title: String
    let url: URL
}
#endif
