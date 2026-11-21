import AppKit
import Foundation

enum PasteboardFileURLReader {
    static let legacyFilenamesPboardType = NSPasteboard.PasteboardType(rawValue: "NSFilenamesPboardType")
    static let promisedFileURLPasteboardType = NSPasteboard.PasteboardType(
        rawValue: "com.apple.pasteboard.promised-file-url"
    )
    static let fileURLPasteboardTypes: Set<NSPasteboard.PasteboardType> = [
        .fileURL,
        legacyFilenamesPboardType,
        promisedFileURLPasteboardType,
    ]

    static func hasFileURLType(_ pasteboardTypes: [NSPasteboard.PasteboardType]) -> Bool {
        return pasteboardTypes.contains { fileURLPasteboardTypes.contains($0) }
    }

    static func hasPromisedFileURLType(
        _ pasteboardTypes: [NSPasteboard.PasteboardType]
    ) -> Bool {
        pasteboardTypes.contains(promisedFileURLPasteboardType)
    }

    static func fileURLs(
        from pasteboard: NSPasteboard,
        promisedFileURLs: [URL]? = nil
    ) -> [URL] {
        var fileURLs: [URL] = []

        let objects = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) ?? []
        for object in objects {
            if let url = object as? URL, url.isFileURL {
                fileURLs.append(url.standardizedFileURL)
            }
        }

        if let paths = pasteboard.propertyList(forType: legacyFilenamesPboardType) as? [String] {
            fileURLs.append(
                contentsOf: paths
                    .filter { !$0.isEmpty }
                    .map { URL(fileURLWithPath: $0).standardizedFileURL }
            )
        }

        if let rawFileURL = pasteboard.string(forType: .fileURL),
           let url = URL(string: rawFileURL),
           url.isFileURL {
            fileURLs.append(url.standardizedFileURL)
        }

        fileURLs.append(contentsOf: promisedFileURLs ?? self.promisedFileURLs(from: pasteboard))

        var seen: Set<String> = []
        return fileURLs.filter { url in
            seen.insert(url.path).inserted
        }
    }

    /// Resolves promises separately so callers can retain each URL's provenance.
    static func promisedFileURLs(from pasteboard: NSPasteboard) -> [URL] {
        var fileURLs: [URL] = []
        var didReadPromisedFileURL = false

        for item in pasteboard.pasteboardItems ?? [] {
            guard let rawPromisedFileURL = item.string(
                forType: promisedFileURLPasteboardType
            ),
            let url = URL(string: rawPromisedFileURL),
            url.isFileURL else {
                continue
            }
            fileURLs.append(url.standardizedFileURL)
            didReadPromisedFileURL = true
        }

        // A few providers expose the promised value on the pasteboard rather
        // than on an individual item. Preserve that legacy representation as
        // a fallback after item-level extraction.
        if !didReadPromisedFileURL,
           let rawPromisedFileURL = pasteboard.string(
               forType: promisedFileURLPasteboardType
           ),
           let url = URL(string: rawPromisedFileURL),
           url.isFileURL {
            fileURLs.append(url.standardizedFileURL)
        }

        return fileURLs
    }

}
