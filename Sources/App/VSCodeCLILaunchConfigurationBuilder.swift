import Foundation

enum VSCodeCLILaunchConfigurationBuilder {
    private struct VSCodeProductMetadata: Decodable {
        let dataFolderName: String?
    }

    static func launchConfiguration(
        vscodeApplicationURL: URL,
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        isExecutableAtPath: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        dataAtURL: (URL) -> Data? = { try? Data(contentsOf: $0) },
        contentsOfDirectoryAtURL: (URL) -> [URL] = { url in
            (try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []
        },
        contentModificationDateAtURL: (URL) -> Date? = { url in
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }
    ) -> VSCodeCLILaunchConfiguration? {
        let contentsURL = vscodeApplicationURL.appendingPathComponent("Contents", isDirectory: true)
        let environment = nodeSafeEnvironment(from: baseEnvironment)

        // Prefer the `code-tunnel serve-web` wrapper. It owns the CLI
        // secret-storage/keyring setup that VS Code Web uses to persist GitHub
        // auth + Settings Sync across reloads/folder changes/app relaunches.
        // Launching the cached `code-server` binary directly bypasses that path
        // and loses the auth/settings state (issue #6595).
        let codeTunnelURL = contentsURL.appendingPathComponent("Resources/app/bin/code-tunnel", isDirectory: false)
        if isExecutableAtPath(codeTunnelURL.path) {
            var codeTunnelEnvironment = environment
            codeTunnelEnvironment["ELECTRON_RUN_AS_NODE"] = "1"
            return VSCodeCLILaunchConfiguration(
                executableURL: codeTunnelURL,
                argumentsPrefix: ["serve-web"],
                environment: codeTunnelEnvironment,
                launcherKind: .codeTunnelWrapper
            )
        }

        // Fallback: the cached code-server binary for installs without the wrapper.
        if let codeServerURL = preferredCachedCodeServerURL(
            contentsURL: contentsURL,
            homeDirectoryURL: homeDirectoryURL,
            isExecutableAtPath: isExecutableAtPath,
            dataAtURL: dataAtURL,
            contentsOfDirectoryAtURL: contentsOfDirectoryAtURL,
            contentModificationDateAtURL: contentModificationDateAtURL
        ) {
            var codeServerEnvironment = environment
            codeServerEnvironment.removeValue(forKey: "ELECTRON_RUN_AS_NODE")
            return VSCodeCLILaunchConfiguration(
                executableURL: codeServerURL,
                argumentsPrefix: [],
                environment: codeServerEnvironment,
                launcherKind: .cachedCodeServer
            )
        }

        return nil
    }

    private static func nodeSafeEnvironment(from baseEnvironment: [String: String]) -> [String: String] {
        var environment = baseEnvironment
        environment.removeValue(forKey: "VSCODE_NODE_OPTIONS")
        environment.removeValue(forKey: "VSCODE_NODE_REPL_EXTERNAL_MODULE")
        if let nodeOptions = environment["NODE_OPTIONS"] {
            environment["VSCODE_NODE_OPTIONS"] = nodeOptions
        }
        if let nodeReplExternalModule = environment["NODE_REPL_EXTERNAL_MODULE"] {
            environment["VSCODE_NODE_REPL_EXTERNAL_MODULE"] = nodeReplExternalModule
        }
        environment.removeValue(forKey: "NODE_OPTIONS")
        environment.removeValue(forKey: "NODE_REPL_EXTERNAL_MODULE")
        return environment
    }

    private static func preferredCachedCodeServerURL(
        contentsURL: URL,
        homeDirectoryURL: URL,
        isExecutableAtPath: (String) -> Bool,
        dataAtURL: (URL) -> Data?,
        contentsOfDirectoryAtURL: (URL) -> [URL],
        contentModificationDateAtURL: (URL) -> Date?
    ) -> URL? {
        let dataFolderName = vscodeDataFolderName(
            contentsURL: contentsURL,
            dataAtURL: dataAtURL
        )
        let serveWebCacheURL = homeDirectoryURL
            .appendingPathComponent(dataFolderName, isDirectory: true)
            .appendingPathComponent("cli/serve-web", isDirectory: true)

        if let orderedCacheIDs = serveWebLRUCacheIDs(
            serveWebCacheURL: serveWebCacheURL,
            dataAtURL: dataAtURL
        ) {
            for cacheID in orderedCacheIDs {
                let codeServerURL = serveWebCacheURL
                    .appendingPathComponent(cacheID, isDirectory: true)
                    .appendingPathComponent("bin/code-server", isDirectory: false)
                if isExecutableAtPath(codeServerURL.path) {
                    return codeServerURL
                }
            }
        }

        let candidates = contentsOfDirectoryAtURL(serveWebCacheURL)
            .map {
                $0.appendingPathComponent("bin/code-server", isDirectory: false)
            }
            .filter {
                isExecutableAtPath($0.path)
            }
            .sorted { lhs, rhs in
                let lhsDate = contentModificationDateAtURL(lhs) ?? .distantPast
                let rhsDate = contentModificationDateAtURL(rhs) ?? .distantPast
                if lhsDate != rhsDate {
                    return lhsDate > rhsDate
                }
                return lhs.path > rhs.path
            }

        return candidates.first
    }

    private static func vscodeDataFolderName(
        contentsURL: URL,
        dataAtURL: (URL) -> Data?
    ) -> String {
        let productURL = contentsURL.appendingPathComponent("Resources/app/product.json", isDirectory: false)
        guard let data = dataAtURL(productURL),
              let product = try? JSONDecoder().decode(VSCodeProductMetadata.self, from: data),
              let dataFolderName = product.dataFolderName,
              isSafePathComponent(dataFolderName) else {
            return ".vscode"
        }
        return dataFolderName
    }

    private static func serveWebLRUCacheIDs(
        serveWebCacheURL: URL,
        dataAtURL: (URL) -> Data?
    ) -> [String]? {
        let lruURL = serveWebCacheURL.appendingPathComponent("lru.json", isDirectory: false)
        guard let data = dataAtURL(lruURL),
              let cacheIDs = try? JSONDecoder().decode([String].self, from: data) else {
            return nil
        }
        return cacheIDs.filter(isSafePathComponent)
    }

    private static func isSafePathComponent(_ component: String) -> Bool {
        guard !component.isEmpty, component != ".", component != ".." else { return false }
        return component.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\")) == nil
    }
}
