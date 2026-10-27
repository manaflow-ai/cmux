import Foundation

/// Parses the ISO 8601 timestamps mobile RPC payloads carry, with or without
/// fractional seconds. A bare whole-second ISO 8601 parser rejects
/// `2026-09-30T22:44:53.481Z`, so the fractional form is tried first.
///
/// The two parse styles are `Sendable` values (`Date.ISO8601FormatStyle`), so
/// the parser is a plain `Sendable` value. A decode entry point creates one
/// parser and passes it to `init(from:)` through ``decoder()``, so every row
/// in a payload reuses it.
struct MobileRPCISO8601DateParser: Sendable {
    /// The `userInfo` key that carries the parser into `init(from:)`. Optional because
    /// `CodingUserInfoKey.init?(rawValue:)` is failable (it never fails for this literal; a
    /// test pins that). Without it, each row makes its own parser.
    static let userInfoKey = CodingUserInfoKey(rawValue: "cmux.mobileRPC.iso8601DateParser")

    private let fractionalSeconds: Date.ISO8601FormatStyle
    private let wholeSeconds: Date.ISO8601FormatStyle

    init() {
        fractionalSeconds = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        wholeSeconds = Date.ISO8601FormatStyle()
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
        (try? fractionalSeconds.parse(raw)) ?? (try? wholeSeconds.parse(raw))
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
