public import Foundation

/// The outcome of resolving the `browser.import.dialog`
/// `destination_profile` query against the app's browser profiles.
public enum ControlBrowserImportProfileResolution: Sendable, Equatable {
    /// The query matched (or created) a profile.
    case resolved(UUID)
    /// Creation was requested but failed (legacy `invalid_params` /
    /// "destination_profile could not be created").
    case createFailed
    /// No match and no creation requested (legacy `invalid_params` /
    /// "destination_profile does not match a cmux browser profile").
    case noMatch
}
