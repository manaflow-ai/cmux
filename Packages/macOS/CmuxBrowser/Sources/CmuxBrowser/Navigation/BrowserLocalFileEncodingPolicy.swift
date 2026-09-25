public import Foundation
public import WebKit

/// Selects UTF-8 for bounded, regular local text files while preserving WebKit's original fallback.
@MainActor
public final class BrowserLocalFileEncodingPolicy {
    private static let defaultTextEncodingSelector = NSSelectorFromString("_setDefaultTextEncodingName:")
    private static let maximumInspectedFileSize = 16 * 1024 * 1024
    private static let maximumMetadataSize = 64 * 1024

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
    public func prepare(for url: URL) async {
        preparationID &+= 1
        let currentPreparationID = preparationID
        let encodingName = await Self.preferredEncodingName(for: url)
        guard currentPreparationID == preparationID else { return }
        setDefaultTextEncodingName(encodingName ?? fallbackEncodingName)
    }

    /// Returns UTF-8 only for a regular, bounded local file whose bytes are valid UTF-8.
    ///
    /// - Parameter url: The candidate local-file destination.
    /// - Returns: `"UTF-8"` for an eligible file, otherwise `nil`.
    public static func preferredEncodingName(for url: URL) async -> String? {
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
            return text.contains("<meta") && text.contains("charset")
        }
        return text.contains("<?xml") && text.contains("encoding")
    }
}
