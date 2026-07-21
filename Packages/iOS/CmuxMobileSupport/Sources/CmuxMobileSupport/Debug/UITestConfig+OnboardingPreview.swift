#if DEBUG
import Foundation

/// Debug-only onboarding and scanner fixture flags.
public extension UITestConfig {
    static var onboardingPreviewEnabled: Bool {
        onboardingPreviewEnabled(from: ProcessInfo.processInfo.environment)
    }

    static func onboardingPreviewEnabled(from env: [String: String]) -> Bool {
        env["CMUX_UITEST_ONBOARDING_PREVIEW"] == "1"
    }

    static var onboardingConnectionFallbackEnabled: Bool {
        onboardingConnectionFallbackEnabled(from: ProcessInfo.processInfo.environment)
    }

    static func onboardingConnectionFallbackEnabled(from env: [String: String]) -> Bool {
        env["CMUX_UITEST_ONBOARDING_CONNECTION_FALLBACK"] == "1"
    }

    static var pairingScannerPreviewEnabled: Bool {
        pairingScannerPreviewEnabled(from: ProcessInfo.processInfo.environment)
    }

    static func pairingScannerPreviewEnabled(from env: [String: String]) -> Bool {
        env["CMUX_UITEST_SCANNER_PREVIEW"] == "1"
    }
}
#endif
