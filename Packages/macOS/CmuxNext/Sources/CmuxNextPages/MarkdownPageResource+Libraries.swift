public import Foundation

extension MarkdownPageResource {
    /// `__lib/<name>`: the classic viewer's bundles (``PageDescriptor/markdownLibraries(inAppResources:)``),
    /// concatenated in load order. The markdown page and the agent pane's charts load the same bytes.
    public nonisolated static let libraryFiles: [String: [String]] = ["ondine.js": ["ondine.min.js"], "mermaid.js": ["mermaid.min.js"], "vega.js": ["vega.min.js", "vega-lite.min.js"]]

    /// The library `name` from `folder`, its files joined in load order; nil for a name not in
    /// ``libraryFiles`` or a file that cannot be read. The app stores them packed and unpacks each
    /// into its caches on first use (``PackedResource``); `packed` is where (a test passes its own).
    @concurrent public nonisolated static func library(_ name: String, in folder: URL, packed: PackedResource = .app) async -> Data? {
        guard let names = libraryFiles[name] else { return nil }
        var parts: [Data] = []
        for file in names {
            // concurrency-allow: @concurrent, off the main actor
            guard let data = packed.data(folder.appending(path: file)) else { return nil }
            parts.append(data)
        }
        return Data(parts.joined(separator: Data("\n;\n".utf8)))
    }
}
