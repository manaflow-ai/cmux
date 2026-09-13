import Foundation

// Bundled shell identity is shared by navigation and native bridge validation.
extension AgentSessionWebRendererCoordinator {
    nonisolated static func shellURL(
        rendererKind: AgentSessionRendererKind,
        resourceDirectoryURL: URL
    ) -> URL {
        rendererKind.resourceHTMLPathComponents.reduce(resourceDirectoryURL) {
            $0.appendingPathComponent($1, isDirectory: false)
        }
    }

    nonisolated static func isTrustedShellURL(_ candidate: URL?, expected: URL?) -> Bool {
        guard let candidate = normalizedTrustedFileURL(candidate),
              let expected = normalizedTrustedFileURL(expected) else {
            return false
        }
        return candidate == expected
    }

    nonisolated static func normalizedTrustedFileURL(_ url: URL?) -> URL? {
        guard let url, url.isFileURL else {
            return nil
        }
        return url.standardizedFileURL.resolvingSymlinksInPath()
    }
}
