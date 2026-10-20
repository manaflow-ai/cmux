/// A strongly-typed handle to a secret string persisted in its own private file.
///
/// `SecretFileKey` is the third key flavor in ``CmuxSettings``, alongside
/// ``DefaultsKey`` (UserDefaults) and ``JSONKey`` (the cmux JSON config). It
/// exists for values that must not live in the shared, user-editable
/// `cmux.json` (for example, the socket-control password): each secret is
/// stored in its own `0600` file rather than serialized into the config.
///
/// The matching store is ``SecretFileStore``. The secret lives at
/// `<baseDirectory>/<fileName>`, where `baseDirectory` is supplied by the
/// store (the app uses `~/.config/cmux`, the same directory as `cmux.json`).
///
/// ```swift
/// public let socketPassword = SecretFileKey(
///     id: "automation.socketPassword",
///     fileName: "socket-control-password"
/// )
/// ```
public struct SecretFileKey: Sendable, Equatable {
    /// The dotted identifier (matches the convention used by other key flavors).
    public let id: String

    /// The on-disk file name for this secret, resolved under the store's base directory.
    public let fileName: String

    /// The value returned when the secret file is absent or empty.
    public let defaultValue: String

    /// Creates a secret-file key.
    ///
    /// `fileName` must be a bare file name: ``SecretFileStore`` resolves it with
    /// `appendingPathComponent`, which would otherwise treat `/` or `..` as path
    /// navigation and let a secret escape the store's base directory. A value
    /// containing a path separator or `..` is a programmer error and traps.
    ///
    /// - Parameters:
    ///   - id: The dotted identifier.
    ///   - fileName: The file name (no path separators, no `..`) under the store's base directory.
    ///   - defaultValue: The fallback when the file is missing or empty; defaults to `""`.
    public init(id: String, fileName: String, defaultValue: String = "") {
        precondition(
            !fileName.isEmpty
                && !fileName.contains("/")
                && !fileName.contains("\\")
                && fileName != "."
                && !fileName.contains(".."),
            "SecretFileKey.fileName must be a bare file name without path separators or '..': \(fileName)"
        )
        self.id = id
        self.fileName = fileName
        self.defaultValue = defaultValue
    }
}
