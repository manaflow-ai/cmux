import Foundation

/// How an import maps one or more source profiles onto cmux destination
/// profiles.
public enum BrowserImportDestinationMode: Equatable, Sendable {
    /// Import every selected source profile into a single destination profile.
    case singleDestination
    /// Import each source profile into its own matching destination profile.
    case separateProfiles
    /// Merge several source profiles into one chosen destination profile.
    case mergeIntoOne
}
