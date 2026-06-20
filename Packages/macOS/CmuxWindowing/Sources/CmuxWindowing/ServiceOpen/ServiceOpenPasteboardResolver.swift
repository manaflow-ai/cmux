public import AppKit

/// The production ``ServiceOpenResolving``, lifted byte-for-byte from
/// AppDelegate's `servicePathURLs(from:)`.
///
/// It first asks the injected ``ServiceFileURLReading`` for the file URLs
/// carried directly on the pasteboard. When that is empty, it falls back to
/// the pasteboard's plain `.string` value, splitting it on newlines and
/// turning each trimmed line into a file URL: a line that already parses as a
/// `file:` URL is used as-is, otherwise it is treated as a filesystem path.
/// An empty pasteboard yields an empty array.
///
/// Design: the resolver holds only an immutable injected reader, so it owns
/// the resolution orchestration without any mutable state. The file-URL
/// decoding stays behind the seam (the app target's `PasteboardFileURLReader`
/// also feeds the terminal image-transfer path), keeping this type a real
/// instance with a constructor-injected collaborator rather than a static
/// utility namespace.
@MainActor
public struct ServiceOpenPasteboardResolver: ServiceOpenResolving {
    private let fileURLReader: any ServiceFileURLReading

    /// Creates a resolver over a file-URL reading seam.
    /// - Parameter fileURLReader: Reads the file URLs carried directly on a
    ///   pasteboard; consulted before the raw-string fallback.
    public init(fileURLReader: any ServiceFileURLReading) {
        self.fileURLReader = fileURLReader
    }

    /// Resolves the candidate path URLs from `pasteboard`; see
    /// ``ServiceOpenResolving/pathURLs(from:)`` for the contract.
    public func pathURLs(from pasteboard: NSPasteboard) -> [URL] {
        let pathURLs = fileURLReader.fileURLs(from: pasteboard)
        if !pathURLs.isEmpty {
            return pathURLs
        }

        if let raw = pasteboard.string(forType: .string), !raw.isEmpty {
            return raw
                .split(whereSeparator: \.isNewline)
                .map { line in
                    let text = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
                    if let fileURL = URL(string: text), fileURL.isFileURL {
                        return fileURL
                    }
                    return URL(fileURLWithPath: text)
                }
        }

        return []
    }
}
