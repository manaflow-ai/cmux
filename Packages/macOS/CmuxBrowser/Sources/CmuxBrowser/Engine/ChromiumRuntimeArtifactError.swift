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
        case .downloadFailed(let message):
            let format = String(
                localized: "browser.chromium.runtime.downloadFailed",
                defaultValue: "Chromium runtime download failed: %@",
                bundle: .module
            )
            return String.localizedStringWithFormat(format, message)
        case .checksumMismatch(let expected, let actual):
            let format = String(
                localized: "browser.chromium.runtime.checksumMismatch",
                defaultValue: "Chromium runtime checksum mismatch (expected %@, got %@)",
                bundle: .module
            )
            return String.localizedStringWithFormat(format, expected, actual)
        case .extractionFailed(let message):
            let format = String(
                localized: "browser.chromium.runtime.extractionFailed",
                defaultValue: "Chromium runtime extraction failed: %@",
                bundle: .module
            )
            return String.localizedStringWithFormat(format, message)
        }
    }

    var errorDescription: String? { description }
}
