import Foundation

/// Loads the bundled CodeMirror editor shell from Resources/markdown-editor.
@MainActor
final class MarkdownCodeMirrorAssets {
    static let shared = MarkdownCodeMirrorAssets()

    private let shellTemplate: String
    private let editorJS: String

    private init() {
        shellTemplate = Self.loadAsset(name: "shell", ext: "html")
        editorJS = Self.loadAsset(name: "editor.bundle", ext: "js")
    }

    func shellHTML() -> String {
        shellTemplate.replacingOccurrences(of: "{{editorJS}}", with: editorJS)
    }

    private static func loadAsset(name: String, ext: String) -> String {
        let bundle = Bundle.main
        let candidates: [URL?] = [
            bundle.url(forResource: name, withExtension: ext, subdirectory: "markdown-editor"),
            bundle.url(forResource: name, withExtension: ext)
        ]
        for case let url? in candidates {
            if let s = try? String(contentsOf: url, encoding: .utf8) {
                return s
            }
        }
#if DEBUG
        NSLog("MarkdownCodeMirrorAssets: missing bundled asset \(name).\(ext)")
#endif
        preconditionFailure("Missing bundled markdown editor asset \(name).\(ext)")
    }
}
