import Foundation

/// The one email scanner every account-privacy test uses (this file is
/// shared by symlink with CmuxNextAppTests). It is deliberately independent
/// of the production redactor and stricter than any email grammar: every
/// `@`, full-width `＠` or URL-encoded `%40` counts as a leak unless it
/// directly follows `…` (the redactor's `s…@e…` form).
nonisolated enum PrivacyScan {
    /// Each unredacted marker in `text`, with a little context.
    static func emails(in text: String) -> [String] {
        let scalars = Array(text.unicodeScalars)
        var found: [String] = []
        for index in scalars.indices {
            let scalar = scalars[index]
            let isAt = scalar == "@" || scalar == "\u{FF20}"
            let isEncoded = scalar == "%" && index + 2 < scalars.count && scalars[index + 1] == "4" && scalars[index + 2] == "0"
            guard isAt || isEncoded, index == 0 || scalars[index - 1] != "\u{2026}" else { continue }
            let context = scalars[max(0, index - 12)..<min(scalars.count, index + 12)]
            found.append(String(String.UnicodeScalarView(context)))
        }
        return found
    }

    /// Leaks anywhere in `value`: every string reached by walking its
    /// `Mirror` recursively (labels included), every leaf's description,
    /// its `description`, its `debugDescription` and its `dump`.
    static func emails(inReflectionOf value: Any) -> [String] {
        var texts = [String(describing: value), String(reflecting: value)]
        var dumped = ""
        dump(value, to: &dumped)
        texts.append(dumped)
        collect(value, into: &texts, depth: 0)
        return texts.flatMap(emails(in:))
    }

    /// Leaks in a JSON document: every key and string after JSON unescaping
    /// (so `…` counts as `…`), or the raw text when it is not JSON.
    static func emails(inJSON data: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return emails(in: String(decoding: data, as: UTF8.self))
        }
        var texts: [String] = []
        collectJSON(object, into: &texts)
        return texts.flatMap(emails(in:))
    }

    private static func collectJSON(_ value: Any, into texts: inout [String]) {
        switch value {
        case let string as String: texts.append(string)
        case let array as [Any]: for item in array { collectJSON(item, into: &texts) }
        case let object as [String: Any]:
            for (key, item) in object {
                texts.append(key)
                collectJSON(item, into: &texts)
            }
        default: break
        }
    }

    private static func collect(_ value: Any, into texts: inout [String], depth: Int) {
        guard depth < 16 else { return }
        if let string = value as? String { texts.append(string) }
        let mirror = Mirror(reflecting: value)
        if mirror.children.isEmpty { texts.append(String(describing: value)) }
        for child in mirror.children {
            if let label = child.label { texts.append(label) }
            collect(child.value, into: &texts, depth: depth + 1)
        }
    }
}
