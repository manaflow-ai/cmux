import Foundation

/// Resolves the Subrouter sidecar shared by the app pane and bundled cmux CLI.
enum SubrouterExecutable {
    static let environmentKey = "CMUX_SUBROUTER_BIN"

    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main,
        executableURL: URL? = Bundle.main.executableURL,
        fileManager: FileManager = .default
    ) -> URL? {
        for candidate in candidates(
            environment: environment,
            bundle: bundle,
            executableURL: executableURL
        ) where fileManager.isExecutableFile(atPath: candidate.path) {
            return candidate.standardizedFileURL
        }
        return nil
    }

    static func candidates(
        environment: [String: String],
        bundle: Bundle,
        executableURL: URL?
    ) -> [URL] {
        var result: [URL] = []
        var seen = Set<String>()

        func append(_ url: URL?) {
            guard let url else { return }
            let normalized = url.standardizedFileURL
            guard seen.insert(normalized.path).inserted else { return }
            result.append(normalized)
        }

        if let override = environment[environmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            append(URL(fileURLWithPath: NSString(string: override).expandingTildeInPath))
        }

        append(bundle.resourceURL?
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("subrouter", isDirectory: false))
        append(bundle.bundleURL
            .appendingPathComponent("Contents/Resources/bin/subrouter", isDirectory: false))

        if let executableURL {
            let executableDirectory = executableURL.deletingLastPathComponent()
            append(executableDirectory.appendingPathComponent("subrouter", isDirectory: false))

            var ancestor = executableDirectory.standardizedFileURL
            while ancestor.path != "/" {
                if ancestor.pathExtension == "app" {
                    append(ancestor.appendingPathComponent("Contents/Resources/bin/subrouter", isDirectory: false))
                    break
                }
                let parent = ancestor.deletingLastPathComponent().standardizedFileURL
                guard parent.path != ancestor.path else { break }
                ancestor = parent
            }
        }

        // Source-tree fallback for tests and direct development runs.
        append(URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/bin/subrouter", isDirectory: false))
        return result
    }
}
