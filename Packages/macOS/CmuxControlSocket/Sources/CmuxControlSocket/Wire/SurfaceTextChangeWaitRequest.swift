internal import CryptoKit
internal import Foundation

/// Parsed params of `surface.wait_text_change`: wait until a terminal's text
/// differs from a revision the caller already saw, or until a timeout.
///
/// The method answers with the same payload as `surface.read_text` plus
/// `revision` (an opaque token for that text) and `changed`. A call without
/// `after_revision` answers at once, so a caller's loop is: read, decide,
/// then wait with the revision it got back. The app wakes the wait on the
/// terminal's own output, not on a timer.
public struct SurfaceTextChangeWaitRequest: Sendable, Equatable {
    /// Default wait when `timeout_ms` is absent.
    public static let defaultTimeoutMilliseconds: Int64 = 30_000
    /// Longest wait one call may ask for (ten minutes, the `--timeout` cap of
    /// `cmux chief dispatch`).
    public static let maximumTimeoutMilliseconds: Int64 = 600_000
    private static let hexDigits = Array("0123456789abcdef".utf8)

    /// The params that only this method reads. Everything else selects and
    /// shapes the read exactly as `surface.read_text` does.
    static let ownKeys: Set<String> = ["after_revision", "timeout_ms"]

    /// The revision the caller already saw, or nil to answer at once.
    public let afterRevision: String?
    /// How long to wait for the text to change.
    public let timeout: Duration
    /// The params to read the terminal with (`surface.read_text` params).
    public let readParams: [String: JSONValue]

    /// Why the params were refused, for an `invalid_params` reply.
    public struct ParseError: Error, Equatable, Sendable {
        public let message: String
    }

    /// Parses the method's params.
    ///
    /// - `after_revision`: optional non-empty string from an earlier reply.
    /// - `timeout_ms`: optional whole number from 0 to
    ///   ``maximumTimeoutMilliseconds``; default ``defaultTimeoutMilliseconds``.
    public static func parse(_ params: [String: JSONValue]) -> Result<SurfaceTextChangeWaitRequest, ParseError> {
        var afterRevision: String?
        switch params["after_revision"] {
        case nil, .null?:
            afterRevision = nil
        case .string(let value)?:
            guard !value.isEmpty else {
                return .failure(ParseError(message: "after_revision must be a non-empty string"))
            }
            afterRevision = value
        default:
            return .failure(ParseError(message: "after_revision must be a non-empty string"))
        }

        let milliseconds: Int64
        switch params["timeout_ms"] {
        case nil, .null?:
            milliseconds = defaultTimeoutMilliseconds
        case .int(let value)?:
            milliseconds = value
        case .double(let value)? where value.rounded() == value && abs(value) <= Double(Int64.max / 2):
            milliseconds = Int64(value)
        default:
            return .failure(ParseError(message: timeoutMessage))
        }
        guard (0...maximumTimeoutMilliseconds).contains(milliseconds) else {
            return .failure(ParseError(message: timeoutMessage))
        }

        return .success(SurfaceTextChangeWaitRequest(
            afterRevision: afterRevision,
            timeout: .milliseconds(milliseconds),
            readParams: params.filter { !ownKeys.contains($0.key) }
        ))
    }

    /// The opaque revision of a terminal's text: equal texts give equal revisions.
    public static func revision(of text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        var bytes: [UInt8] = []
        bytes.reserveCapacity(32)
        for byte in digest.prefix(16) {
            bytes.append(hexDigits[Int(byte >> 4)])
            bytes.append(hexDigits[Int(byte & 0x0f)])
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Whether text with `revision` answers this wait: the caller saw nothing
    /// yet, or the text differs from what it saw.
    public func isAnswered(byRevision revision: String) -> Bool {
        afterRevision != revision
    }

    private static let timeoutMessage = "timeout_ms must be a whole number of milliseconds from 0 to \(maximumTimeoutMilliseconds)"
}
