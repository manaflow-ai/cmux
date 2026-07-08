public import Foundation

/// Finds installed OWL Chromium runtime directories on disk.
///
/// Search order:
/// 1. The directory named by the `CMUX_CHROMIUM_RUNTIME_DIR` environment variable.
/// 2. Version subdirectories of the default install root
///    (`~/Library/Application Support/cmux/chromium-runtime`), newest first.
///
/// ```swift
/// let locator = ChromiumRuntimeLocator()
/// let bundle = try locator.locate()
/// ```
public struct ChromiumRuntimeLocator {
    /// Environment variable that overrides the runtime search path.
    public static let environmentOverrideKey = "CMUX_CHROMIUM_RUNTIME_DIR"

    // FileManager is documented thread-safe for path queries; OK to hold nonisolated.
    private nonisolated(unsafe) let fileManager: FileManager
    private let environment: [String: String]
    private let installRootOverride: URL?

    /// Creates a locator.
    ///
    /// - Parameters:
    ///   - fileManager: Filesystem access seam; tests pass a default manager with temp paths.
    ///   - environment: Process environment; tests pass a fixed dictionary.
    ///   - installRoot: Overrides the default install root; tests pass a temp directory.
    public init(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        installRoot: URL? = nil
    ) {
        self.fileManager = fileManager
        self.environment = environment
        self.installRootOverride = installRoot
    }

    /// The directory the fetch script installs runtimes into, one subdirectory per version.
    public var installRoot: URL {
        if let installRootOverride {
            return installRootOverride
        }
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("cmux/chromium-runtime", isDirectory: true)
    }

    /// Finds the best available runtime.
    ///
    /// - Returns: The runtime from the environment override when set, otherwise
    ///   the most recently modified valid runtime under ``installRoot``.
    /// - Throws: ``ChromiumRuntimeError/runtimeNotFound(searched:)`` when no
    ///   valid runtime exists, or the validation error for an explicitly
    ///   overridden directory that is invalid.
    public func locate() throws -> ChromiumRuntimeBundle {
        if let override = environment[Self.environmentOverrideKey], !override.isEmpty {
            return try bundle(at: URL(fileURLWithPath: override, isDirectory: true))
        }
        var searched: [URL] = []
        let root = installRoot
        searched.append(root)
        let candidates = (try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let ordered = candidates.sorted { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lhsDate > rhsDate
        }
        for candidate in ordered {
            if let bundle = try? bundle(at: candidate) {
                return bundle
            }
            searched.append(candidate)
        }
        throw ChromiumRuntimeError.runtimeNotFound(searched: searched)
    }

    /// Validates one runtime directory and returns its bundle.
    ///
    /// - Parameter directory: Root of an extracted runtime archive.
    /// - Throws: ``ChromiumRuntimeError/invalidRuntimeDirectory(_:missing:)``
    ///   when the dylib or Content Shell executable is absent.
    public func bundle(at directory: URL) throws -> ChromiumRuntimeBundle {
        let library = directory.appendingPathComponent(ChromiumRuntimeBundle.libraryFileName)
        guard fileManager.fileExists(atPath: library.path) else {
            throw ChromiumRuntimeError.invalidRuntimeDirectory(directory, missing: ChromiumRuntimeBundle.libraryFileName)
        }
        let shell = directory.appendingPathComponent(ChromiumRuntimeBundle.contentShellExecutablePath)
        guard fileManager.fileExists(atPath: shell.path) else {
            throw ChromiumRuntimeError.invalidRuntimeDirectory(directory, missing: ChromiumRuntimeBundle.contentShellExecutablePath)
        }
        var manifest: ChromiumRuntimeManifest?
        let manifestURL = directory.appendingPathComponent(ChromiumRuntimeBundle.manifestFileName)
        if let data = try? Data(contentsOf: manifestURL) {
            manifest = try? ChromiumRuntimeManifest(data: data)
        }
        return ChromiumRuntimeBundle(
            rootDirectory: directory,
            libraryURL: library,
            contentShellExecutableURL: shell,
            manifest: manifest
        )
    }
}
