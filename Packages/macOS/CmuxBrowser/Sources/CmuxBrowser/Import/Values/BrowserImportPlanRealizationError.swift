public import Foundation

/// Errors raised while realizing a ``BrowserImportExecutionPlan`` against the
/// cmux profile store.
public enum BrowserImportPlanRealizationError: LocalizedError {
    /// The plan referenced a destination profile id that no longer exists.
    case missingDestinationProfile(UUID)
    /// The store could not create the named destination profile.
    case profileCreationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingDestinationProfile:
            return String(
                localized: "browser.import.error.destinationMissing",
                defaultValue: "The selected cmux browser profile no longer exists. Pick a destination profile again."
            )
        case .profileCreationFailed(let name):
            return String(
                format: String(
                    localized: "browser.import.error.destinationCreateFailed",
                    defaultValue: "cmux could not create the destination profile \"%@\"."
                ),
                name
            )
        }
    }
}
