import Foundation

/// The one email scanner every account-privacy test uses (this file is
/// shared by symlink with CmuxNextAppTests). It is deliberately separate
/// from the production redactor, so a gap in one is caught by the other.
nonisolated enum PrivacyScan {
    static let emailPattern = #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9\-]+(\.[A-Za-z0-9\-]+)*\.[A-Za-z]{2,}"#

    /// Every email-shaped substring of `text`.
    static func emails(in text: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: emailPattern) else { return ["<bad pattern>"] }
        let range = NSRange(text.startIndex..., in: text)
        return expression.matches(in: text, range: range).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    /// Emails anywhere in `value`: every string reached by walking its
    /// `Mirror` recursively, every leaf's description, its `description`,
    /// its `debugDescription` and its `dump`.
    static func emails(inReflectionOf value: Any) -> [String] {
        var texts = [String(describing: value), String(reflecting: value)]
        var dumped = ""
        dump(value, to: &dumped)
        texts.append(dumped)
        collect(value, into: &texts, depth: 0)
        return texts.flatMap(emails(in:))
    }

    /// Emails anywhere in a JSON document.
    static func emails(inJSON data: Data) -> [String] {
        emails(in: String(decoding: data, as: UTF8.self))
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
