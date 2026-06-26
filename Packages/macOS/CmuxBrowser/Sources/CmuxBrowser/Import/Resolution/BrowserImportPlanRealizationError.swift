public import Foundation

/// A failure encountered while realizing a ``BrowserImportExecutionPlan`` against
/// the live cmux profile store.
///
/// Each case carries its already-localized, user-facing message so the message
/// is resolved in the app bundle (via ``BrowserImportRealizationStrings``) rather
/// than inside this package. ``errorDescription`` returns that stored message, so
/// `error.localizedDescription` surfaces the faithful localized text.
public enum BrowserImportPlanRealizationError: LocalizedError {
    /// The selected destination profile identifier no longer resolves to a profile.
    case missingDestinationProfile(UUID, localizedMessage: String)
    /// Creating the named destination profile failed.
    case profileCreationFailed(name: String, localizedMessage: String)

    public var errorDescription: String? {
        switch self {
        case .missingDestinationProfile(_, let localizedMessage):
            return localizedMessage
        case .profileCreationFailed(_, let localizedMessage):
            return localizedMessage
        }
    }
}
