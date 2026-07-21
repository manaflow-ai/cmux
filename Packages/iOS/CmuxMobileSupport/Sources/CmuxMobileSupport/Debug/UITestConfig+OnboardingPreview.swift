#if DEBUG
import Foundation

/// Debug-only onboarding and scanner fixture flags.
public extension UITestConfig {
    /// Whether the deterministic onboarding preview is enabled.
    static var onboardingPreviewEnabled: Bool {
        isOnboardingPreviewEnabled(in: ProcessInfo.processInfo.environment)
    }

    /// Whether the onboarding preview should render its fallback connection state.
    static var onboardingConnectionFallbackEnabled: Bool {
        isOnboardingConnectionFallbackEnabled(in: ProcessInfo.processInfo.environment)
    }

    /// Whether the deterministic pairing-scanner preview is enabled.
    static var pairingScannerPreviewEnabled: Bool {
        isPairingScannerPreviewEnabled(in: ProcessInfo.processInfo.environment)
    }
}

func isOnboardingPreviewEnabled(in env: [String: String]) -> Bool {
    env["CMUX_UITEST_ONBOARDING_PREVIEW"] == "1"
}

func isOnboardingConnectionFallbackEnabled(in env: [String: String]) -> Bool {
    env["CMUX_UITEST_ONBOARDING_CONNECTION_FALLBACK"] == "1"
}

func isPairingScannerPreviewEnabled(in env: [String: String]) -> Bool {
    env["CMUX_UITEST_SCANNER_PREVIEW"] == "1"
}
#endif
