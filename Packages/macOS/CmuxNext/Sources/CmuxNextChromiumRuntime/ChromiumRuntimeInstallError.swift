/// Why one install attempt of a Chromium runtime pack failed.
public enum ChromiumRuntimeInstallError: Error, Equatable, Sendable {
    /// The server answered with this HTTP status.
    case http(Int)
    /// The transfer failed (offline, reset, timeout); the message says why.
    case transfer(String)
    /// The downloaded file is not the pinned size.
    case sizeMismatch(expected: Int64, actual: Int64)
    /// The downloaded file does not hash to the pinned sha256.
    case checksumMismatch
    /// The pack holds an absolute path, a `..` component or a symlink that
    /// leaves the pack.
    case unsafeEntry(String)
    /// `tar` failed; the message is its output.
    case unpack(String)
    /// The pack lacks a required item (the runtime folder, the framework, the shim
    /// or a helper).
    case missing(String)
    /// A code signature check failed for this item.
    case signature(String)
    /// Moving the pack into place or writing its record failed.
    case filesystem(String)
    /// A step stopped before it ran (its task was cancelled, or quit dropped it). Not a failed attempt:
    /// ``ChromiumRuntimeInstaller`` ends the job without publishing a failure or retrying, and nothing
    /// was vouched for.
    case cancelled

    /// Stable code for diagnostics (`debug.cef`).
    public var code: String {
        switch self {
        case .http: "http"
        case .transfer: "transfer"
        case .sizeMismatch: "sizeMismatch"
        case .checksumMismatch: "checksumMismatch"
        case .unsafeEntry: "unsafeEntry"
        case .unpack: "unpack"
        case .missing: "missing"
        case .signature: "signature"
        case .filesystem: "filesystem"
        case .cancelled: "cancelled"
        }
    }

    /// A one-line English description for logs and `debug.cef` (the UI shows
    /// a localized summary instead).
    public var detail: String {
        switch self {
        case .http(let status): "HTTP \(status)"
        case .transfer(let message): message
        case .sizeMismatch(let expected, let actual): "size \(actual), expected \(expected)"
        case .checksumMismatch: "sha256 does not match the pin"
        case .unsafeEntry(let entry): "unsafe entry \(entry)"
        case .unpack(let message): message
        case .missing(let item): "missing \(item)"
        case .signature(let item): "signature check failed: \(item)"
        case .filesystem(let message): message
        case .cancelled: "cancelled"
        }
    }
}
