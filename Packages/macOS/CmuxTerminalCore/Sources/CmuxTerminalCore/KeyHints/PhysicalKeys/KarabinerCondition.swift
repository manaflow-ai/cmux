import Foundation

/// One entry of a complex modification's `conditions`.
///
/// Only conditions cmux can decide are modeled: which app is frontmost
/// (cmux) and which keyboard sent the key. Anything else (variables, input
/// sources, keyboard types) is ``unsupported``, and a rule that depends on it
/// can't be inverted with confidence.
enum KarabinerCondition: Sendable, Equatable {
    case frontmostApplication(bundleIdentifiers: [String], filePaths: [String], negated: Bool)
    case device(identifiers: [KarabinerDeviceIdentifiers], negated: Bool)
    case unsupported

    init(json: [String: Any]) {
        switch json["type"] as? String {
        case "frontmost_application_if", "frontmost_application_unless":
            self = .frontmostApplication(
                bundleIdentifiers: json["bundle_identifiers"] as? [String] ?? [],
                filePaths: json["file_paths"] as? [String] ?? [],
                negated: json["type"] as? String == "frontmost_application_unless"
            )
        case "device_if", "device_unless":
            let identifiers = (json["identifiers"] as? [[String: Any]] ?? []).map(KarabinerDeviceIdentifiers.init(json:))
            self = .device(identifiers: identifiers, negated: json["type"] as? String == "device_unless")
        default:
            self = .unsupported
        }
    }

    /// Whether the condition holds for a key from `device` while
    /// `application` is frontmost, or `nil` when that can't be told.
    ///
    /// - Parameter device: The keyboard the key comes from; `nil` when unknown.
    func holds(device: KeyboardDevice?, application: KarabinerFrontmostApplication) -> Bool? {
        switch self {
        case .unsupported:
            return nil
        case let .frontmostApplication(bundleIdentifiers, filePaths, negated):
            let matched = Self.anyMatch(bundleIdentifiers, application.bundleIdentifier)
                || Self.anyMatch(filePaths, application.executablePath)
            return matched != negated
        case let .device(identifiers, negated):
            guard let device else { return nil }
            var matched: Bool? = false
            for identifier in identifiers {
                switch identifier.matches(device) {
                case true?: matched = true
                case nil where matched == false: matched = nil
                default: break
                }
                if matched == true { break }
            }
            return matched.map { $0 != negated }
        }
    }

    /// Whether any of Karabiner's regular expressions matches `value`.
    private static func anyMatch(_ patterns: [String], _ value: String?) -> Bool {
        guard let value else { return false }
        let range = NSRange(value.startIndex..., in: value)
        return patterns.contains { pattern in
            (try? NSRegularExpression(pattern: pattern))?.firstMatch(in: value, range: range) != nil
        }
    }
}
