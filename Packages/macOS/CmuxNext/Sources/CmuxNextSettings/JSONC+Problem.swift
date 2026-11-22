import Foundation

extension JSONC {
    /// A file's read or parse failure as a person reads it: where in the file and what, such as
    /// "unexpected character 'x' at line 5, column 3". Never the error's dump: the toast and the
    /// Settings row showed "Error Domain=NSCocoaErrorDomain Code=3840 … UserInfo={…}" (Leo,
    /// 2026-11-20: "bad toast of unreadable json").
    public static func problem(_ error: any Error, in source: String?) -> String {
        if let failure = error as? Failure {
            switch failure {
            case .unterminatedComment: return "a /* comment is never closed"
            case .unterminatedString: return "a string is never closed"
            case .malformed(let offset):
                guard let source else { return "the text is not valid JSON" }
                return "the text is not valid JSON at \(position(of: offset, in: source))"
            }
        }
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == CocoaError.propertyListReadCorrupt.rawValue {
            // JSONSerialization: its debug text names the place ("Unexpected character 'x' around
            // line 5, column 3."); line numbers hold because comments keep their line breaks.
            if let detail = ns.userInfo[NSDebugDescriptionErrorKey] as? String, !detail.isEmpty {
                return sentence(detail)
            }
            if let index = ns.userInfo["NSJSONSerializationErrorIndex"] as? Int, let source {
                return "the text is not valid JSON at \(position(of: index, in: source))"
            }
            return "the text is not valid JSON"
        }
        return sentence(ns.localizedDescription)
    }

    /// "line L, column C" (both from 1) of UTF-8 byte `offset` in `source`.
    static func position(of offset: Int, in source: String) -> String {
        var line = 1
        var column = 1
        for byte in source.utf8.prefix(max(0, offset)) {
            if byte == 0x0A {
                line += 1
                column = 1
            } else if byte & 0xC0 != 0x80 {
                column += 1
            }
        }
        return "line \(line), column \(column)"
    }

    /// One clause to sit inside "could not be read (…)": first letter lowercased, "around" as
    /// "at", no closing period.
    private static func sentence(_ text: String) -> String {
        var out = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while out.hasSuffix(".") { out.removeLast() }
        out = out.replacingOccurrences(of: " around line ", with: " at line ")
        guard let first = out.first, first.isUppercase, !(out.dropFirst().first?.isUppercase ?? false) else { return out }
        return first.lowercased() + out.dropFirst()
    }
}
