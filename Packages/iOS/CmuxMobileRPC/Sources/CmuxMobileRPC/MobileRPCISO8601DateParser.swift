import Foundation

/// Parses the ISO 8601 timestamps mobile RPC payloads carry, with or without
/// fractional seconds. A bare `ISO8601DateFormatter` accepts whole seconds
/// only, so `2026-09-30T22:44:53.481Z` would otherwise read as malformed.
///
/// A decode entry point creates one parser and passes it to `init(from:)`
/// through ``decoder()``, so every row in a payload reuses the same formatters.
struct MobileRPCISO8601DateParser: Sendable {
    /// The `userInfo` key that carries the parser into `init(from:)`. Optional because
    /// `CodingUserInfoKey.init?(rawValue:)` is failable (it never fails for this literal; a
    /// test pins that). Without it, each row makes its own parser.
    static let userInfoKey = CodingUserInfoKey(rawValue: "cmux.mobileRPC.iso8601DateParser")

    // `ISO8601DateFormatter` is documented thread-safe, and these are never
    // mutated after `init`, so sharing them across isolation domains is safe.
    nonisolated(unsafe) private let fractionalSeconds: ISO8601DateFormatter
    nonisolated(unsafe) private let wholeSeconds: ISO8601DateFormatter

    init() {
        let fractionalSeconds = ISO8601DateFormatter()
        fractionalSeconds.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.fractionalSeconds = fractionalSeconds
        wholeSeconds = ISO8601DateFormatter()
    }

    /// The parser a decode entry point passed in, or a new one when decoding
    /// started somewhere that didn't pass one.
    init(injectedInto decoder: any Decoder) {
        self = Self.userInfoKey.flatMap { decoder.userInfo[$0] } as? MobileRPCISO8601DateParser
            ?? MobileRPCISO8601DateParser()
    }

    /// - Parameter raw: The wire timestamp.
    /// - Returns: The date, or `nil` when `raw` isn't an ISO 8601 date-time.
    func date(from raw: String) -> Date? {
        fractionalSeconds.date(from: raw) ?? wholeSeconds.date(from: raw)
    }

    /// A JSON decoder that passes this parser to `init(from:)`.
    func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        if let key = Self.userInfoKey {
            decoder.userInfo[key] = self
        }
        return decoder
    }
}
