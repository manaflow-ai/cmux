import Foundation

/// Errors that ``JSONConfigStore`` raises when the on-disk file exists but
/// cannot be parsed.
///
/// File-not-found is **not** an error — it is the legitimate empty-state
/// signal that the user has not yet written any settings. Reads in that
/// state return key defaults. Everything else (malformed JSON / JSONC,
/// top-level value that is not an object, sanitizer failure) propagates
/// to the caller, who decides whether to fall back to defaults (reads)
/// or refuse to mutate (writes).
public enum JSONConfigStoreReadError: Error, Equatable, Sendable {
    /// The on-disk file decoded to JSON, but the top-level value is not
    /// an object (`{ ... }`). cmux's config schema requires a top-level
    /// object; arrays, strings, numbers, etc. are unrecoverable.
    case notADictionary
}
