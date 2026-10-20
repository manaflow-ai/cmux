import CmuxNextPages
import Foundation

/// Discovers passive HTTPS icons from a bounded, possibly truncated HTML document.
struct AgentPaneSourceIconHTML: Sendable {
    nonisolated init() {}

    nonisolated func candidates(in data: Data, pageURL: URL) -> [URL] {
        let tags = scan(data)
        let baseHref = tags.baseHref?.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = baseHref.flatMap { URL(string: $0, relativeTo: pageURL)?.absoluteURL } ?? pageURL
        var ranked: [(url: URL, touch: Bool, distance: Int, format: Int, index: Int)] = []
        for (index, link) in tags.links.enumerated() {
            guard let rel = link["rel"]?.lowercased(),
                  let href = link["href"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !href.isEmpty else { continue }
            let tokens = Set(rel.split(whereSeparator: \.isWhitespace).map(String.init))
            let touch = tokens.contains("apple-touch-icon") || tokens.contains("apple-touch-icon-precomposed")
            guard !tokens.contains("mask-icon"), tokens.contains("icon") || touch,
                  let resolved = URL(string: href, relativeTo: base)?.absoluteURL,
                  var components = URLComponents(url: resolved, resolvingAgainstBaseURL: false) else { continue }
            // Fragments are never sent in a GET and cannot make an already-tried icon new.
            components.fragment = nil
            guard let url = components.url, GuardedRemoteFetch.allows(url) else { continue }
            let sizes = link["sizes"] ?? ""
            let distances = sizes.lowercased().split(whereSeparator: \.isWhitespace).compactMap { size -> Int? in
                let dimensions = size.split(separator: "x")
                guard dimensions.count == 2, let width = Int(dimensions[0]), let height = Int(dimensions[1]),
                      (1...4096).contains(width), (1...4096).contains(height) else { return nil }
                return max(0, 32 - min(width, height)) + max(0, max(width, height) - 64)
            }
            let type = link["type"]?.lowercased().split(separator: ";", maxSplits: 1).first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // Refuse advertised SVG before it can consume a fallback request.
            let suffix = url.pathExtension.lowercased()
            guard type != "image/svg+xml", !["svg", "svgz"].contains(suffix) else { continue }
            let format: Int
            if ["image/png", "image/x-icon", "image/vnd.microsoft.icon"].contains(type) || ["png", "ico"].contains(suffix) {
                format = 0
            } else {
                format = 2
            }
            ranked.append((url, touch, distances.min() ?? Int.max, format, index))
        }
        ranked.sort {
            if $0.touch != $1.touch { return !$0.touch }
            if $0.distance != $1.distance { return $0.distance < $1.distance }
            if $0.format != $1.format { return $0.format < $1.format }
            return $0.index < $1.index
        }
        var seen = Set<URL>()
        return ranked.compactMap { seen.insert($0.url).inserted ? $0.url : nil }
    }

    /// Scans only a bounded head prefix; no HTML or XML framework sees remote bytes.
    private nonisolated func scan(_ data: Data) -> (baseHref: String?, links: [[String: String]]) {
        let bytes = Array(data.prefix(256 * 1024))
        var cursor = 0
        var baseHref: String?
        var links: [[String: String]] = []
        var rawText: String?
        var templateDepth = 0
        let rawTags: Set<String> = ["script", "style", "noscript", "textarea", "title"]
        while cursor < bytes.count {
            guard bytes[cursor] == 60 else { cursor += 1; continue } // <
            // Comments are markup only outside raw text elements.
            if rawText == nil, bytes[cursor...].starts(with: [60, 33, 45, 45]) {
                cursor += 4
                while cursor < bytes.count, !bytes[cursor...].starts(with: [45, 45, 62]) { cursor += 1 }
                cursor = min(bytes.count, cursor + 3)
                continue
            }
            cursor += 1
            let closing = cursor < bytes.count && bytes[cursor] == 47
            if closing { cursor += 1 }
            let nameStart = cursor
            while cursor < bytes.count, !isSpace(bytes[cursor]), bytes[cursor] != 47, bytes[cursor] != 62, bytes[cursor] != 60 {
                cursor += 1
            }
            let name = asciiLowercase(bytes[nameStart..<cursor])
            if let rawText {
                guard closing && name == rawText else { continue }
            }
            let capture = rawText == nil && templateDepth == 0 && !closing
                && ((name == "link" && links.count < 64) || (name == "base" && baseHref == nil))
            guard let attributes = readTag(bytes, cursor: &cursor, capture: capture) else { break }
            if rawText != nil { rawText = nil; continue }
            if name == "template" {
                if closing { templateDepth = max(0, templateDepth - 1) } else { templateDepth += 1 }
                continue
            }
            if !closing, rawTags.contains(name) { rawText = name; continue }
            guard templateDepth == 0 else { continue }
            if (closing && name == "head") || (!closing && name == "body") { break }
            guard !closing else { continue }
            if name == "base", baseHref == nil, let href = attributes["href"] { baseHref = href }
            if name == "link", links.count < 64 { links.append(attributes) }
        }
        return (baseHref, links)
    }

    /// Consumes a complete start/end tag, retaining only icon attributes with bounded values.
    private nonisolated func readTag(_ bytes: [UInt8], cursor: inout Int, capture: Bool) -> [String: String]? {
        var attributes: [String: String] = [:]
        var seen = Set<String>()
        while cursor < bytes.count {
            if isSpace(bytes[cursor]) || bytes[cursor] == 47 { cursor += 1; continue }
            if bytes[cursor] == 62 { cursor += 1; return attributes }
            let start = cursor
            while cursor < bytes.count, !isSpace(bytes[cursor]),
                  bytes[cursor] != 61, bytes[cursor] != 62, bytes[cursor] != 47 { cursor += 1 }
            let name = capture ? asciiLowercase(bytes[start..<cursor]) : ""
            // Always advance even on malformed attributes such as a bare '='.
            if cursor == start { cursor += 1; continue }
            while cursor < bytes.count, isSpace(bytes[cursor]) { cursor += 1 }
            var value = cursor..<cursor
            if cursor < bytes.count, bytes[cursor] == 61 {
                cursor += 1
                while cursor < bytes.count, isSpace(bytes[cursor]) { cursor += 1 }
                guard cursor < bytes.count else { return nil }
                let quote = bytes[cursor]
                if quote == 34 || quote == 39 {
                    cursor += 1
                    let valueStart = cursor
                    while cursor < bytes.count, bytes[cursor] != quote { cursor += 1 }
                    guard cursor < bytes.count else { return nil }
                    value = valueStart..<cursor
                    cursor += 1
                } else {
                    let valueStart = cursor
                    while cursor < bytes.count, !isSpace(bytes[cursor]), bytes[cursor] != 62 { cursor += 1 }
                    value = valueStart..<cursor
                }
            }
            if ["href", "rel", "sizes", "type"].contains(name), seen.insert(name).inserted, value.count <= 2048 {
                attributes[name] = decodeEntities(bytes[value])
            }
        }
        return nil
    }

    private nonisolated func isSpace(_ byte: UInt8) -> Bool {
        byte == 32 || (9...13).contains(byte)
    }

    private nonisolated func asciiLowercase(_ bytes: ArraySlice<UInt8>) -> String {
        String(decoding: bytes.map { (65...90).contains($0) ? $0 + 32 : $0 }, as: UTF8.self)
    }

    /// Decodes only the supported, semicolon-terminated entities, leaving unknown text intact.
    private nonisolated func decodeEntities(_ value: ArraySlice<UInt8>) -> String {
        let bytes = Array(value)
        let named = ["amp": "&", "quot": "\"", "#39": "'", "#x27": "'", "lt": "<", "gt": ">"]
        var result: [UInt8] = []
        var cursor = 0
        while cursor < bytes.count {
            if bytes[cursor] == 38 {
                var end = cursor + 1
                // Stop at another entity so failed matches never rescan a long suffix.
                while end < bytes.count, bytes[end] != 59, bytes[end] != 38 { end += 1 }
                if end < bytes.count, bytes[end] == 59 {
                    let entity = String(decoding: bytes[(cursor + 1)..<end], as: UTF8.self)
                    var replacement = named[entity]
                    if replacement == nil, entity.hasPrefix("#") {
                        let hex = entity.hasPrefix("#x") || entity.hasPrefix("#X")
                        let digits = entity.dropFirst(hex ? 2 : 1)
                        let validDigits = !digits.isEmpty && digits.utf8.allSatisfy {
                            (48...57).contains($0) || (hex && ((65...70).contains($0) || (97...102).contains($0)))
                        }
                        if validDigits, let code = UInt32(digits, radix: hex ? 16 : 10), let scalar = Unicode.Scalar(code) {
                            replacement = String(scalar)
                        }
                    }
                    if let replacement {
                        result.append(contentsOf: replacement.utf8)
                        cursor = end + 1
                        continue
                    }
                }
                result.append(contentsOf: bytes[cursor..<end])
                cursor = end
                continue
            }
            result.append(bytes[cursor])
            cursor += 1
        }
        return String(decoding: result, as: UTF8.self)
    }
}
