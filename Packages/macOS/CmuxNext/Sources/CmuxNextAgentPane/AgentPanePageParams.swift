import Foundation

/// Strict reads of a page request's params as WebKit bridges them. A key the
/// request does not take, or a key with the wrong type, refuses the whole
/// request: the session host refuses unknown fields too (`extra: false`), and
/// a refusal here is never sent. A JavaScript `null` (`NSNull`) is absent.
nonisolated struct AgentPanePageParams {
    struct Malformed: Error {}

    private let values: [String: Any]

    /// Throws when `params` name a key outside `allowed`.
    init(_ params: [String: Any]?, allowed: Set<String>) throws {
        let values = (params ?? [:]).filter { !($0.value is NSNull) }
        guard values.keys.allSatisfy({ allowed.contains($0) }) else { throw Malformed() }
        self.values = values
    }

    /// An absolute folder with no NUL.
    func folder(_ key: String) throws -> String {
        guard let folder = AgentPaneGitRequest.folder(values[key]) else { throw Malformed() }
        return folder
    }

    /// A nonempty string with no NUL; nil when absent.
    func text(_ key: String) throws -> String? {
        guard let value = values[key] else { return nil }
        guard let text = value as? String, !text.isEmpty, !text.contains("\u{0}") else { throw Malformed() }
        return text
    }

    func requiredText(_ key: String) throws -> String {
        guard let text = try text(key) else { throw Malformed() }
        return text
    }

    /// An idempotency key as the resource envelope takes it: 1-128 UTF-8
    /// bytes with no control characters; nil when absent.
    func key(_ key: String) throws -> String? {
        guard let text = try text(key) else { return nil }
        guard text.utf8.count <= 128,
              !text.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { throw Malformed() }
        return text
    }

    /// A JavaScript boolean (a `CFBoolean`; a number is not one); nil when absent.
    func flag(_ key: String) throws -> Bool? {
        guard let value = values[key] else { return nil }
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw Malformed() }
        return number.boolValue
    }

    /// A positive whole number (a boolean is not one); nil when absent.
    func count(_ key: String) throws -> Int? {
        guard let value = values[key] else { return nil }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let count = Int(exactly: number.doubleValue), count > 0 else { throw Malformed() }
        return count
    }

    /// An array of nonempty strings with no NUL; nil when absent.
    func texts(_ key: String) throws -> [String]? {
        guard let value = values[key] else { return nil }
        guard let items = value as? [Any] else { throw Malformed() }
        var texts: [String] = []
        for item in items {
            guard let text = item as? String, !text.isEmpty, !text.contains("\u{0}") else { throw Malformed() }
            texts.append(text)
        }
        return texts
    }

    /// A nested object read as strictly; nil when absent.
    func object(_ key: String, allowed: Set<String>) throws -> AgentPanePageParams? {
        guard let value = values[key] else { return nil }
        guard let object = value as? [String: Any] else { throw Malformed() }
        return try AgentPanePageParams(object, allowed: allowed)
    }

    /// Whether `key` is present.
    func has(_ key: String) -> Bool {
        values[key] != nil
    }
}
