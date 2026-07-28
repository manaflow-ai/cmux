import Foundation

/// A color override used by the programmable Dynamic Notch appearance.
public enum DynamicNotchAppearanceColor: Sendable, Equatable, Hashable {
    /// Use the native color for the token's semantic role.
    case system

    /// Use a normalized `#RRGGBB` color.
    case hex(String)

    /// Parses `system` or a six-digit RGB color.
    ///
    /// - Parameter rawValue: `system`, `#RRGGBB`, or `RRGGBB`.
    public init?(rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.caseInsensitiveCompare("system") == .orderedSame {
            self = .system
            return
        }

        let digits = trimmed.hasPrefix("#")
            ? String(trimmed.dropFirst())
            : trimmed
        guard digits.count == 6, UInt32(digits, radix: 16) != nil else {
            return nil
        }
        self = .hex("#\(digits.uppercased())")
    }

    /// The canonical string used by CLI assignments and UserDefaults storage.
    public var rawValue: String {
        switch self {
        case .system:
            "system"
        case .hex(let value):
            value
        }
    }
}
