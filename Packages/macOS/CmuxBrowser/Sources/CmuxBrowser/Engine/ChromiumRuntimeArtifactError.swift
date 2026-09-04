import Foundation

/// Localized failures while downloading or installing the managed runtime.
enum ChromiumRuntimeArtifactError: Error, Equatable, Sendable, CustomStringConvertible, LocalizedError {
    case executableNotFound
    case unsupportedPlatform
    case invalidArchive
    case downloadFailed(String)
    case checksumMismatch(expected: String, actual: String)
    case extractionFailed(String)

    var description: String {
        switch self {
        case .executableNotFound:
            return String(
                localized: "browser.chromium.runtime.executableNotFound",
                defaultValue: "The managed Chromium runtime is not installed",
                bundle: .module
            )
        case .unsupportedPlatform:
            return String(
                localized: "browser.chromium.runtime.unsupportedPlatform",
                defaultValue: "The managed Chromium runtime is unavailable for this Mac",
                bundle: .module
            )
        case .invalidArchive:
            return String(
                localized: "browser.chromium.runtime.invalidArchive",
                defaultValue: "The Chromium runtime archive is invalid",
                bundle: .module
            )
        case .downloadFailed:
            return String(
                localized: "browser.chromium.runtime.downloadFailed",
                defaultValue: "Unable to download Chromium. Try again.",
                bundle: .module
            )
        case .checksumMismatch:
            return String(
                localized: "browser.chromium.runtime.checksumMismatch",
                defaultValue: "Chromium download verification failed. Try again.",
                bundle: .module
            )
        case .extractionFailed:
            return String(
                localized: "browser.chromium.runtime.extractionFailed",
                defaultValue: "Unable to install Chromium. Try again.",
                bundle: .module
            )
        }
    }

    var errorDescription: String? { description }
}
