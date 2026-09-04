public import Foundation

/// Coordinates managed shell integration with the declarative login mode.
///
/// The legacy ``TerminalSurface`` environment helpers remain available for
/// callers that need the default login integration. This instance service adds
/// the non-login decision without putting another static utility namespace on
/// the terminal surface type.
public struct TerminalShellStartupCoordinator {
    private let fileManager: FileManager

    /// Creates a coordinator with an injectable filesystem seam.
    ///
    /// - Parameter fileManager: Filesystem used when rebuilding fish/nushell
    ///   commands for non-login startup.
    public init(fileManager: FileManager = FileManager()) {
        self.fileManager = fileManager
    }

    /// Applies managed integration environment values and chooses its launch
    /// command for the requested shell mode.
    ///
    /// - Parameters:
    ///   - shell: Resolved user-shell executable path.
    ///   - integrationDir: Bundled cmux integration directory.
    ///   - userGhosttyShellIntegrationMode: User's Ghostty integration mode.
    ///   - shellStartupMode: Declarative login/non-login preference.
    ///   - environment: Environment updated with managed values.
    ///   - protectedKeys: Keys that later overlays cannot replace.
    ///   - readFile: Injectable reader for shell bootstrap files.
    /// - Returns: A managed command override, or `nil` when the native launch
    ///   command should remain in charge.
    public func apply(
        shell: String,
        integrationDir: String,
        userGhosttyShellIntegrationMode: String,
        shellStartupMode: TerminalShellStartupMode,
        to environment: inout [String: String],
        protectedKeys: inout Set<String>,
        readFile: (String) throws -> String = { try String(contentsOfFile: $0, encoding: .utf8) }
    ) -> String? {
        let nativeCommand = TerminalSurface.applyManagedShellSpecificStartupEnvironment(
            shell: shell,
            integrationDir: integrationDir,
            userGhosttyShellIntegrationMode: userGhosttyShellIntegrationMode,
            to: &environment,
            protectedKeys: &protectedKeys,
            readFile: readFile
        )
        guard shellStartupMode == .nonLogin else { return nativeCommand }

        let shellName = URL(fileURLWithPath: shell).lastPathComponent
        switch shellName {
        case "zsh", "bash":
            // The legacy helper has already installed the shell-integration
            // environment. Route the shell through `env` so Ghostty's login
            // wrapper cannot reintroduce the login flag.
            return TerminalShellStartupPolicy().nonLoginShellCommand(
                shell: shell,
                arguments: "-i"
            )
        case "fish":
            guard nativeCommand != nil else { return nil }
            return TerminalShellIntegrationCommandBuilder().managedFishShellCommand(
                shell: shell,
                mode: .nonLogin
            )
        case "nu":
            guard nativeCommand != nil else { return nil }
            let bootstrapPath = (integrationDir as NSString)
                .appendingPathComponent("nushell/cmux-nushell-bootstrap.nu")
            guard let bootstrap = try? readFile(bootstrapPath) else { return nil }
            let integrationFileIsReadable: (String) -> Bool = { [fileManager] path in
                fileManager.isReadableFile(atPath: path)
            }
            let payload = TerminalSurface.nushellStartupPayload(
                bootstrapContents: bootstrap,
                integrationDir: integrationDir,
                integrationFileIsReadable: integrationFileIsReadable
            )
            guard !payload.isEmpty else { return nil }
            return TerminalShellIntegrationCommandBuilder().managedNushellShellCommand(
                shell: shell,
                startupPayload: payload,
                mode: .nonLogin
            )
        default:
            return nativeCommand
        }
    }
}
