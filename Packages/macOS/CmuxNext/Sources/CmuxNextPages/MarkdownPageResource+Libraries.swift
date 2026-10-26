public import CmuxNextCompat
public import Foundation

extension MarkdownPageResource {
    /// `__lib/<name>`: the classic viewer's bundles (``PageDescriptor/markdownLibraries(inAppResources:)``),
    /// concatenated in load order. The markdown page and the agent pane's charts load the same bytes.
    public nonisolated static let libraryFiles: [String: [String]] = ["ondine.js": ["ondine.min.js"], "mermaid.js": ["mermaid.min.js"], "vega.js": ["vega.min.js", "vega-lite.min.js"]]

    /// The library `name` from `folder`, its files joined in load order; nil for a name not in
    /// ``libraryFiles`` or a file that cannot be read. The page waits for it: read on `runner`'s files lane.
    public nonisolated static func library(_ name: String, in folder: URL, runner: any MayBlockRunner) async -> Data? {
        guard let names = libraryFiles[name] else { return nil }
        let joined = try? await runner.runFiles(.userVisible) { () -> Data? in
            var parts: [Data] = []
            for file in names {
                guard let data = try? Data(contentsOf: folder.appending(path: file)) else { return nil }
                parts.append(data)
            }
            return Data(parts.joined(separator: Data("\n;\n".utf8)))
        }
        return joined ?? nil
    }
}
