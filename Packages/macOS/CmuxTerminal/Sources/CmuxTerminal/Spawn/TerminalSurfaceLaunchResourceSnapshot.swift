public import Foundation

/// Fixed app-bundle resources used while assembling terminal launches.
///
/// The bundle does not change during a normal process lifetime. Inspect these
/// paths once, off the main thread, then share this immutable value across all
/// terminal launch resolutions.
public struct TerminalSurfaceLaunchResourceSnapshot: Sendable, Equatable {
    /// The app bundle directory that contains command wrappers.
    public let wrapperDirectoryURL: URL?
    /// The command wrapper directory to prepend to `PATH`.
    public let cliBinPath: String?
    /// The bundled `cmux` executable path.
    public let bundledCLIPath: String?
    /// The bundled `ghostty` executable path.
    public let ghosttyCLIPath: String?
    /// The bundled shell integration directory path.
    public let shellIntegrationDirectoryPath: String?

    /// Creates an immutable bundle resource snapshot.
    public init(
        wrapperDirectoryURL: URL?,
        cliBinPath: String?,
        bundledCLIPath: String?,
        ghosttyCLIPath: String?,
        shellIntegrationDirectoryPath: String?
    ) {
        self.wrapperDirectoryURL = wrapperDirectoryURL
        self.cliBinPath = cliBinPath
        self.bundledCLIPath = bundledCLIPath
        self.ghosttyCLIPath = ghosttyCLIPath
        self.shellIntegrationDirectoryPath = shellIntegrationDirectoryPath
    }

    /// A snapshot for a launch with no app-bundle resources.
    public static let unavailable = Self(
        wrapperDirectoryURL: nil,
        cliBinPath: nil,
        bundledCLIPath: nil,
        ghosttyCLIPath: nil,
        shellIntegrationDirectoryPath: nil
    )

    nonisolated init(
        resourceURL: URL?,
        isExecutableFile: @Sendable (String) -> Bool,
        directoryExists: @Sendable (String) -> Bool
    ) {
        guard let resourceURL else {
            self = .unavailable
            return
        }
        let wrapperDirectoryURL = resourceURL.appendingPathComponent(
            "bin",
            isDirectory: true
        )
        let bundledCLIPath = wrapperDirectoryURL.appendingPathComponent("cmux").path
        let ghosttyCLIPath = wrapperDirectoryURL.appendingPathComponent("ghostty").path
        let shellIntegrationDirectoryPath = resourceURL.appendingPathComponent(
            "shell-integration",
            isDirectory: true
        ).path
        self.init(
            wrapperDirectoryURL: wrapperDirectoryURL,
            cliBinPath: wrapperDirectoryURL.path,
            bundledCLIPath: isExecutableFile(bundledCLIPath) ? bundledCLIPath : nil,
            ghosttyCLIPath: isExecutableFile(ghosttyCLIPath) ? ghosttyCLIPath : nil,
            shellIntegrationDirectoryPath: directoryExists(shellIntegrationDirectoryPath)
                ? shellIntegrationDirectoryPath
                : nil
        )
    }
}
