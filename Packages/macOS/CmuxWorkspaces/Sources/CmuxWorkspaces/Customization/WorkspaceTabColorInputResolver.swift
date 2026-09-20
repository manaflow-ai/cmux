import Foundation

/// Resolves a user-provided workspace tab color against an injected palette.
public struct WorkspaceTabColorInputResolver: Sendable {
    /// A named color accepted by the resolver.
    public struct NamedColor: Sendable, Equatable {
        /// The case-insensitive name users can enter.
        public let name: String
        /// The normalized `#RRGGBB` value returned for the name.
        public let hex: String

        /// Creates a named color.
        /// - Parameters:
        ///   - name: The case-insensitive name users can enter.
        ///   - hex: The color's `#RRGGBB` value.
        public init(name: String, hex: String) {
            self.name = name
            self.hex = hex
        }
    }

    /// The result of resolving a color input.
    public enum Resolution: Sendable, Equatable {
        /// The normalized `#RRGGBB` color.
        case resolved(String)
        /// No non-whitespace input was supplied.
        case missing
        /// The input matched neither a palette name nor a six-digit hex color.
        case invalid(namedColors: [String])
    }

    private let namedColors: [NamedColor]

    /// Creates a resolver from the palette currently available to the caller.
    /// - Parameter namedColors: Named colors in the order they should be reported
    ///   when an input is invalid. Entries with empty names or invalid hex values
    ///   are ignored.
    public init(namedColors: [NamedColor]) {
        self.namedColors = namedColors.compactMap { entry in
            let name = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty,
                  let hex = Self.normalizedHex(entry.hex) else {
                return nil
            }
            return NamedColor(name: name, hex: hex)
        }
    }

    /// Resolves a palette name or six-digit hexadecimal color.
    /// - Parameter raw: The optional user input.
    /// - Returns: A normalized color, a missing-input result, or the accepted
    ///   palette names when the input is invalid.
    public func resolve(_ raw: String?) -> Resolution {
        guard let raw else { return .missing }
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return .missing }

        if let entry = namedColors.first(where: {
            $0.name.caseInsensitiveCompare(input) == .orderedSame
        }) {
            return .resolved(entry.hex)
        }
        if let normalized = Self.normalizedHex(input) {
            return .resolved(normalized)
        }
        return .invalid(namedColors: namedColors.map(\.name))
    }

    /// Normalizes a six-digit ASCII hexadecimal color to `#RRGGBB`.
    ///
    /// The leading `#` is optional. Signed values and non-ASCII digits are
    /// rejected even when radix integer parsing would otherwise accept
    /// them.
    ///
    /// - Parameter raw: The hexadecimal color to normalize.
    /// - Returns: The normalized color, or `nil` when the input is not exactly
    ///   six ASCII hexadecimal digits after the optional leading `#`.
    public static func normalizedHex(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let body = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard body.utf8.count == 6,
              body.utf8.allSatisfy({ byte in
                  switch byte {
                  case 48...57, 65...70, 97...102:
                      return true
                  default:
                      return false
                  }
              }) else {
            return nil
        }
        return "#" + body.uppercased()
    }
}
