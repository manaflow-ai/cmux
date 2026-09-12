import Foundation

/// Parses one complete `cmux.json` revision for typed settings consumers.
///
/// The decoder is a value type so callers can inject it in tests and keep all
/// JSON parsing outside UI and terminal creation paths.
struct JSONConfigSnapshotDecoder: Sendable {
    let sanitizer: JSONCSanitizer

    init(sanitizer: JSONCSanitizer = JSONCSanitizer()) {
        self.sanitizer = sanitizer
    }

    func root(fileURL: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        return root(data: data)
    }

    func root(data: Data) -> [String: Any] {
        guard !data.isEmpty,
              let sanitized = try? sanitizer.sanitize(data),
              let object = try? JSONSerialization.jsonObject(with: sanitized),
              let dictionary = object as? [String: Any] else {
            return [:]
        }
        return dictionary
    }

    func value<Value>(for key: JSONKey<Value>, in root: [String: Any]) -> Value {
        key.path.lookup(in: root).flatMap(Value.decodeFromJSON) ?? key.defaultValue
    }

    func readRoot(at url: URL) throws -> [String: Any] {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && error.code == NSFileReadNoSuchFileError {
            return [:]
        }
        if data.isEmpty { return [:] }
        let sanitized = try sanitizer.sanitize(data)
        let object = try JSONSerialization.jsonObject(with: sanitized, options: [])
        guard let dictionary = object as? [String: Any] else {
            throw JSONConfigStoreReadError.notADictionary
        }
        return dictionary
    }
}
