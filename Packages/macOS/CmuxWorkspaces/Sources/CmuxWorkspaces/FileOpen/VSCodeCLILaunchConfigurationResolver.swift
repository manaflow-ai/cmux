public import Foundation

/// Resolves the ``VSCodeCLILaunchConfiguration`` for a VS Code application
/// bundle: prefer a cached `code-server` binary (selected via the serve-web
/// LRU order, then content-modification date), otherwise fall back to the
/// bundle's `code-tunnel` wrapper, sanitizing the Node environment either way.
///
/// A real instance type, not a static namespace: the filesystem and
/// environment seams the legacy `VSCodeCLILaunchConfigurationBuilder` took as
/// defaulted parameters are constructor-injected here so the resolution rules
/// are testable with in-memory fakes. Those seams are non-`Sendable` closures,
/// so the resolver is constructed and used within a single synchronous launch
/// context and is not itself `Sendable`. Byte-faithful lift of the legacy
/// namespace method.
public struct VSCodeCLILaunchConfigurationResolver {
    private struct VSCodeProductMetadata: Decodable {
        let dataFolderName: String?
    }

    private let homeDirectoryURL: URL
    private let baseEnvironment: [String: String]
    private let isExecutableAtPath: (String) -> Bool
    private let dataAtURL: (URL) -> Data?
    private let contentsOfDirectoryAtURL: (URL) -> [URL]
    private let contentModificationDateAtURL: (URL) -> Date?

    /// Creates a resolver. Defaults bind to the live filesystem and process
    /// environment, matching the legacy builder's default parameters.
    public init(
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        isExecutableAtPath: @escaping (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        dataAtURL: @escaping (URL) -> Data? = { try? Data(contentsOf: $0) },
        contentsOfDirectoryAtURL: @escaping (URL) -> [URL] = { url in
            (try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []
        },
        contentModificationDateAtURL: @escaping (URL) -> Date? = { url in
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }
    ) {
        self.homeDirectoryURL = homeDirectoryURL
        self.baseEnvironment = baseEnvironment
        self.isExecutableAtPath = isExecutableAtPath
        self.dataAtURL = dataAtURL
        self.contentsOfDirectoryAtURL = contentsOfDirectoryAtURL
        self.contentModificationDateAtURL = contentModificationDateAtURL
    }

    /// Resolves the launch configuration for the given VS Code application
    /// bundle, or `nil` when neither a cached `code-server` nor a `code-tunnel`
    /// wrapper is available.
    public func launchConfiguration(vscodeApplicationURL: URL) -> VSCodeCLILaunchConfiguration? {
        let contentsURL = vscodeApplicationURL.appendingPathComponent("Contents", isDirectory: true)
        let environment = nodeSafeEnvironment(from: baseEnvironment)

        if let codeServerURL = preferredCachedCodeServerURL(contentsURL: contentsURL) {
            var codeServerEnvironment = environment
            codeServerEnvironment.removeValue(forKey: "ELECTRON_RUN_AS_NODE")
            return VSCodeCLILaunchConfiguration(
                executableURL: codeServerURL,
                argumentsPrefix: [],
                environment: codeServerEnvironment
            )
        }

        let codeTunnelURL = contentsURL.appendingPathComponent("Resources/app/bin/code-tunnel", isDirectory: false)
        guard isExecutableAtPath(codeTunnelURL.path) else { return nil }
        var codeTunnelEnvironment = environment
        codeTunnelEnvironment["ELECTRON_RUN_AS_NODE"] = "1"

        return VSCodeCLILaunchConfiguration(
            executableURL: codeTunnelURL,
            argumentsPrefix: ["serve-web"],
            environment: codeTunnelEnvironment
        )
    }

    private func nodeSafeEnvironment(from baseEnvironment: [String: String]) -> [String: String] {
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

    private func preferredCachedCodeServerURL(contentsURL: URL) -> URL? {
        let dataFolderName = vscodeDataFolderName(contentsURL: contentsURL)
        let serveWebCacheURL = homeDirectoryURL
            .appendingPathComponent(dataFolderName, isDirectory: true)
            .appendingPathComponent("cli/serve-web", isDirectory: true)

        if let orderedCacheIDs = serveWebLRUCacheIDs(serveWebCacheURL: serveWebCacheURL) {
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

    private func vscodeDataFolderName(contentsURL: URL) -> String {
        let productURL = contentsURL.appendingPathComponent("Resources/app/product.json", isDirectory: false)
        guard let data = dataAtURL(productURL),
              let product = try? JSONDecoder().decode(VSCodeProductMetadata.self, from: data),
              let dataFolderName = product.dataFolderName,
              isSafePathComponent(dataFolderName) else {
            return ".vscode"
        }
        return dataFolderName
    }

    private func serveWebLRUCacheIDs(serveWebCacheURL: URL) -> [String]? {
        let lruURL = serveWebCacheURL.appendingPathComponent("lru.json", isDirectory: false)
        guard let data = dataAtURL(lruURL),
              let cacheIDs = try? JSONDecoder().decode([String].self, from: data) else {
            return nil
        }
        return cacheIDs.filter(isSafePathComponent)
    }

    private func isSafePathComponent(_ component: String) -> Bool {
        guard !component.isEmpty, component != ".", component != ".." else { return false }
        return component.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\")) == nil
    }
}
