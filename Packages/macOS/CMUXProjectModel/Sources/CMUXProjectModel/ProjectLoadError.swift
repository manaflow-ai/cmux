import Foundation

/// Errors that ``ProjectAdapter`` implementations can raise when loading a
/// project from disk.
public enum ProjectLoadError: Error, Sendable, Equatable {
    /// The supplied URL does not exist or is not readable.
    case unreadable(URL)

    /// The supplied URL exists but is not the kind of artifact this adapter
    /// can parse (e.g. a directory passed to the Xcode adapter that contains
    /// no `.xcodeproj` or `.xcworkspace`).
    case unsupported(URL)

    /// The artifact exists and is the right kind, but parsing failed.
    ///
    /// The underlying reason is rendered as a string because adapter
    /// implementations wrap third-party errors (XcodeProj, libxml2, etc.)
    /// whose types are not part of this package's public API surface.
    case parseFailure(URL, reason: String)
}
