import Foundation

/// Errors that ``JSONConfigStore`` raises when the on-disk file exists but
/// cannot be parsed or a stored setting cannot be decoded for mutation.
///
/// File-not-found is **not** an error — it is the legitimate empty-state
/// signal that the user has not yet written any settings. Reads in that
/// state return key defaults. Everything else (malformed JSON / JSONC,
/// top-level value that is not an object, sanitizer failure, or a present
/// value with the wrong type) propagates to the caller, who decides whether
/// to fall back to defaults (reads) or refuse to mutate (writes).
public enum JSONConfigStoreReadError: Error, Equatable, Sendable {
    /// The on-disk file decoded to JSON, but the top-level value is not
    /// an object (`{ ... }`). cmux's config schema requires a top-level
    /// object; arrays, strings, numbers, etc. are unrecoverable.
    case notADictionary

    /// A stored value exists for the key but cannot be decoded as the key's
    /// declared value type. Mutations refuse to replace it with a default.
    ///
    /// - Parameter keyID: The dotted identifier of the invalid setting.
    case invalidValue(keyID: String)
}
