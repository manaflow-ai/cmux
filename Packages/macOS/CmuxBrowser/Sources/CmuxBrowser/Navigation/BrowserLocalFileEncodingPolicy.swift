public import Foundation
public import WebKit

/// Selects UTF-8 for bounded, regular local text files while preserving WebKit's original fallback.
@MainActor
public final class BrowserLocalFileEncodingPolicy {
    private static let defaultTextEncodingSelector = NSSelectorFromString("_setDefaultTextEncodingName:")
    nonisolated private static let maximumInspectedFileSize = 16 * 1024 * 1024
    nonisolated private static let maximumMetadataSize = 64 * 1024

    private let preferences: WKPreferences
    private let fallbackEncodingName: String?
    private var preparationID: UInt64 = 0

    /// Creates a policy that captures the preferences' original fallback encoding.
    ///
    /// - Parameter preferences: The WebKit preferences owned by one browser view.
    public init(preferences: WKPreferences) {
        self.preferences = preferences
        fallbackEncodingName = preferences.value(forKey: "_defaultTextEncodingName") as? String
    }

    /// Waits for the local-file probe, then applies either UTF-8 or the captured WebKit fallback.
    ///
    /// - Parameter url: The main-frame destination whose bytes should be classified.
    public func prepare(for url: URL) async -> Bool {
        guard preferences.responds(to: Self.defaultTextEncodingSelector),
              fallbackEncodingName != nil else { return true }
        preparationID &+= 1
        let currentPreparationID = preparationID
        let encodingName = await Self.preferredEncodingName(for: url)
        guard currentPreparationID == preparationID else { return false }
        setDefaultTextEncodingName(encodingName ?? fallbackEncodingName)
        return true
    }

    /// Returns UTF-8 only for a regular, bounded local file whose bytes are valid UTF-8.
    ///
    /// - Parameter url: The candidate local-file destination.
    /// - Returns: `"UTF-8"` for an eligible file, otherwise `nil`.
    nonisolated public static func preferredEncodingName(for url: URL) async -> String? {
        guard url.isFileURL, url.scheme?.caseInsensitiveCompare("file") == .orderedSame else {
            return nil
        }
        return await Task.detached(priority: .utility) {
            Self.inspectRegularFile(at: url) ? "UTF-8" : nil
        }.value
    }

    private func setDefaultTextEncodingName(_ encodingName: String?) {
        guard preferences.responds(to: Self.defaultTextEncodingSelector),
              let encodingName else { return }
        _ = preferences.perform(Self.defaultTextEncodingSelector, with: encodingName)
    }

    nonisolated private static func inspectRegularFile(at url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let fileSize = values.fileSize,
              fileSize <= maximumInspectedFileSize,
              let handle = try? FileHandle(forReadingFrom: url) else {
            return false
        }
        defer { try? handle.close() }

        guard let data = try? handle.read(upToCount: maximumInspectedFileSize + 1),
              data.count <= maximumInspectedFileSize,
              String(data: data, encoding: .utf8) != nil else {
            return false
        }
        return !containsDeclaredHTMLCharacterEncoding(data, url: url)
    }

    nonisolated private static func containsDeclaredHTMLCharacterEncoding(_ data: Data, url: URL) -> Bool {
        let extensionName = url.pathExtension.lowercased()
        guard ["html", "htm", "xhtml", "xml"].contains(extensionName) else { return false }
        let prefix = data.prefix(maximumMetadataSize)
        let text = String(decoding: prefix, as: UTF8.self).lowercased()
        if ["html", "htm", "xhtml"].contains(extensionName) {
            return containsHTMLCharsetDeclaration(in: text)
        }
        return text.contains("<?xml") && text.contains("encoding")
    }

    /// Finds HTML meta elements whose parsed attributes declare a character set.
    nonisolated private static func containsHTMLCharsetDeclaration(in text: String) -> Bool {
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let metaStart = text.range(of: "<meta", range: searchStart..<text.endIndex) {
            let afterName = metaStart.upperBound
            if afterName < text.endIndex,
               !text[afterName].isWhitespace,
               text[afterName] != "/",
               text[afterName] != ">" {
                searchStart = afterName
                continue
            }
            guard let tagEnd = text[afterName...].firstIndex(of: ">") else { break }
            let attributes = htmlAttributes(in: text[afterName..<tagEnd])
            if let charset = attributes["charset"], !charset.isEmpty {
                return true
            }
            if attributes["http-equiv"] == "content-type",
               let content = attributes["content"],
               content.range(of: #"charset\s*="#, options: .regularExpression) != nil {
                return true
            }
            searchStart = text.index(after: tagEnd)
        }
        return false
    }

    /// Parses the ASCII attribute grammar used by an HTML meta element.
    nonisolated private static func htmlAttributes(in source: Substring) -> [String: String] {
        var attributes: [String: String] = [:]
        var index = source.startIndex
        while index < source.endIndex {
            while index < source.endIndex && (source[index].isWhitespace || source[index] == "/") {
                index = source.index(after: index)
            }
            guard index < source.endIndex else { break }
            let nameStart = index
            while index < source.endIndex,
                  source[index].isLetter || source[index].isNumber || source[index] == "-"
                    || source[index] == ":" || source[index] == "_" {
                index = source.index(after: index)
            }
            guard nameStart < index else {
                index = source.index(after: index)
                continue
            }
            let name = String(source[nameStart..<index])
            while index < source.endIndex && source[index].isWhitespace {
                index = source.index(after: index)
            }
            var value = ""
            if index < source.endIndex, source[index] == "=" {
                index = source.index(after: index)
                while index < source.endIndex && source[index].isWhitespace {
                    index = source.index(after: index)
                }
                if index < source.endIndex, source[index] == "\"" || source[index] == "'" {
                    let quote = source[index]
                    index = source.index(after: index)
                    let valueStart = index
                    while index < source.endIndex, source[index] != quote {
                        index = source.index(after: index)
                    }
                    value = String(source[valueStart..<index])
                    if index < source.endIndex { index = source.index(after: index) }
                } else {
                    let valueStart = index
                    while index < source.endIndex && !source[index].isWhitespace {
                        index = source.index(after: index)
                    }
                    value = String(source[valueStart..<index])
                }
            }
            attributes[name] = value
        }
        return attributes
    }
}
