public import Foundation
public import CmuxNextHelperSecurity

/// Picks the binary that serves a VS Code install in the browser and builds its launch.
///
/// A trusted `code-server` that `serve-web` already downloaded wins (most recently used first, from
/// the cache's `lru.json`, else the newest). The server listens on 127.0.0.1 on a free port and
/// accepts only the token in the connection token file. The signed `code-tunnel` wrapper is not a
/// fallback: it delegates to mutable cache scripts without authenticating the full runtime.
///
/// File access goes through the injected closures, so tests describe an install without disk:
///
/// ```swift
/// let planner = VSCodeServeWebLaunchPlanner(
///     homeDirectory: home, environment: [:], isExecutable: { $0.hasSuffix("code-tunnel") },
///     data: { _ in nil }, contents: { _ in [] }, modificationDate: { _ in nil })
/// ```
public struct VSCodeServeWebLaunchPlanner: Sendable {
    /// Microsoft Corporation's reviewed Developer ID Team ID for official VS Code helpers.
    public static let vscodeTeamIdentifier = "UBF8T346G9"
    private let homeDirectory: URL
    private let environment: [String: String]
    private let isExecutable: @Sendable (String) -> Bool
    private let data: @Sendable (URL) -> Data?
    private let contents: @Sendable (URL) -> [URL]
    private let modificationDate: @Sendable (URL) -> Date?
    private let executableTrust: @Sendable (URL) -> Bool

    /// Creates a planner.
    /// - Parameters:
    ///   - homeDirectory: The user's home, where VS Code keeps its `serve-web` cache.
    ///   - environment: The environment the server inherits (the app's).
    ///   - isExecutable: Whether a path is an executable file. Defaults to the file system.
    ///   - data: A file's contents, or nil. Defaults to the file system.
    ///   - contents: A directory's visible entries. Defaults to the file system.
    ///   - modificationDate: A file's modification date. Defaults to the file system.
    ///   - executableTrust: Whether an executable is a direct file signed by Microsoft's VS Code team.
    public init(
        homeDirectory: URL,
        environment: [String: String],
        isExecutable: @escaping @Sendable (String) -> Bool = { FileManager().isExecutableFile(atPath: $0) },
        data: @escaping @Sendable (URL) -> Data? = { try? Data(contentsOf: $0) },
        contents: @escaping @Sendable (URL) -> [URL] = {
            (try? FileManager().contentsOfDirectory(at: $0, includingPropertiesForKeys: [.contentModificationDateKey],
                                                    options: [.skipsHiddenFiles])) ?? []
        },
        modificationDate: @escaping @Sendable (URL) -> Date? = {
            (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }, executableTrust: @escaping @Sendable (URL) -> Bool = { executable in
            HelperExecutableTrust(reference: .teamIdentifier(VSCodeServeWebLaunchPlanner.vscodeTeamIdentifier))
                .accepts(executable)
        }
    ) {
        self.homeDirectory = homeDirectory
        self.environment = environment
        self.isExecutable = isExecutable
        self.data = data
        self.contents = contents
        self.modificationDate = modificationDate
        self.executableTrust = executableTrust
    }

    /// Whether `vscode` already has a directly trusted cached server.
    /// - Parameter vscode: The VS Code app bundle.
    public func canServe(vscode: URL) -> Bool {
        cachedCodeServer(vscode) != nil
    }

    /// The launch that serves `vscode`, or nil when the install has no server binary.
    /// - Parameters:
    ///   - vscode: The VS Code app bundle.
    ///   - connectionTokenFile: The private file holding the connection token.
    public func launch(vscode: URL, connectionTokenFile: URL) -> VSCodeServeWebLaunch? {
        let serverArguments = [
            "--accept-server-license-terms", "--host", "127.0.0.1", "--port", "0",
            "--connection-token-file", connectionTokenFile.path,
        ]
        let childEnvironment = VSCodeServeWebLaunch.minimalEnvironment(environment)
        if let codeServer = cachedCodeServer(vscode) {
            return VSCodeServeWebLaunch(executableURL: codeServer, arguments: serverArguments, environment: childEnvironment)
        }
        return nil
    }

    private func cachedCodeServer(_ vscode: URL) -> URL? {
        let cache = homeDirectory.appendingPathComponent(dataFolderName(vscode), isDirectory: true)
            .appendingPathComponent("cli/serve-web", isDirectory: true)
        func server(in entry: URL) -> URL { entry.appendingPathComponent("bin/code-server", isDirectory: false) }
        if let raw = data(cache.appendingPathComponent("lru.json", isDirectory: false)),
           let ids = try? JSONDecoder().decode([String].self, from: raw) {
            for id in ids where isSafeComponent(id) {
                let candidate = server(in: cache.appendingPathComponent(id, isDirectory: true))
                if isExecutable(candidate.path), executableTrust(candidate) { return candidate }
            }
        }
        return contents(cache).map(server(in:)).filter { isExecutable($0.path) && executableTrust($0) }.max { lhs, rhs in
            let left = modificationDate(lhs) ?? .distantPast, right = modificationDate(rhs) ?? .distantPast
            return left != right ? left < right : lhs.path < rhs.path
        }
    }

    /// The install's data folder (`.vscode`, `.vscode-insiders`) from its `product.json`.
    private func dataFolderName(_ vscode: URL) -> String {
        struct Product: Decodable { let dataFolderName: String? }
        let product = vscode.appendingPathComponent("Contents/Resources/app/product.json", isDirectory: false)
        guard let raw = data(product), let name = (try? JSONDecoder().decode(Product.self, from: raw))?.dataFolderName,
              isSafeComponent(name) else { return ".vscode" }
        return name
    }

    private func isSafeComponent(_ component: String) -> Bool {
        !component.isEmpty && component != "." && component != ".."
            && component.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\")) == nil
    }
}
