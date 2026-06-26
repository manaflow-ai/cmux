public import Foundation

/// A ``FileExplorerProvider`` backed by a remote host reached over SSH.
///
/// Drives an ``SSHFileExplorerTransport`` (process-based by default) to resolve
/// the remote home, list directories, and download files. Availability and the
/// resolved home path are mutable and read from background SSH tasks, so they are
/// guarded by an `NSLock`; `@unchecked Sendable` is safe because every access to
/// that state goes through the lock.
public final class SSHFileExplorerProvider: FileExplorerProvider, @unchecked Sendable {
    private struct State: Sendable {
        var homePath: String
        var isAvailable: Bool
    }

    /// Connection parameters identifying the remote host.
    public let connection: SSHFileExplorerConnection
    /// Human-readable target shown in the file explorer (e.g. `host:port`).
    public let displayTarget: String
    private let transport: SSHFileExplorerTransport
    private let stateLock = NSLock()
    private var state: State

    /// The resolved remote `$HOME`, or empty until resolution completes.
    public var homePath: String {
        stateLock.lock()
        defer { stateLock.unlock() }
        return state.homePath
    }

    /// Whether the remote host is currently reachable for listings.
    public var isAvailable: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return state.isAvailable
    }

    /// SSH destination (`user@host` or host alias).
    public var destination: String { connection.destination }
    /// Optional port override.
    public var port: Int? { connection.port }
    /// Optional identity (private key) file path.
    public var identityFile: String? { connection.identityFile }
    /// Extra `-o` options passed to `ssh`.
    public var sshOptions: [String] { connection.sshOptions }

    /// Creates a provider from raw connection parameters.
    public init(
        destination: String,
        port: Int?,
        identityFile: String?,
        sshOptions: [String],
        displayTarget: String? = nil,
        homePath: String,
        isAvailable: Bool,
        transport: SSHFileExplorerTransport = ProcessSSHFileExplorerTransport.shared
    ) {
        self.connection = SSHFileExplorerConnection(
            destination: destination,
            port: port,
            identityFile: identityFile,
            sshOptions: sshOptions
        )
        self.displayTarget = displayTarget ?? {
            guard let port else { return destination }
            return "\(destination):\(port)"
        }()
        self.transport = transport
        self.state = State(homePath: homePath, isAvailable: isAvailable)
    }

    /// Creates a provider from a prebuilt connection descriptor.
    public init(
        connection: SSHFileExplorerConnection,
        displayTarget: String,
        homePath: String,
        isAvailable: Bool,
        transport: SSHFileExplorerTransport = ProcessSSHFileExplorerTransport.shared
    ) {
        self.connection = connection
        self.displayTarget = displayTarget
        self.transport = transport
        self.state = State(homePath: homePath, isAvailable: isAvailable)
    }

    /// Updates reachability and, when provided, the resolved home path.
    public func updateAvailability(_ available: Bool, homePath: String?) {
        stateLock.lock()
        defer { stateLock.unlock() }
        state.isAvailable = available
        if let homePath {
            state.homePath = homePath
        }
    }

    /// Resolves the remote `$HOME`, throwing if the provider is unavailable or the
    /// remote HOME is empty.
    public func resolveHomePath() async throws -> String {
        guard isAvailable else {
            throw FileExplorerError.providerUnavailable
        }
        let home = try await transport.resolveHomePath(connection: connection)
        guard !home.isEmpty else {
            throw FileExplorerError.sshCommandFailed("remote HOME was empty")
        }
        return home
    }

    /// Lists the children of `path` on the remote host.
    public func listDirectory(path: String, showHidden: Bool) async throws -> [FileExplorerEntry] {
        guard isAvailable else {
            throw FileExplorerError.providerUnavailable
        }
        return try await transport.listDirectory(path: path, connection: connection, showHidden: showHidden)
    }

    /// Downloads the remote file at `path` to `localURL`.
    public func downloadFile(path: String, to localURL: URL) async throws {
        guard isAvailable else {
            throw FileExplorerError.providerUnavailable
        }
        try await transport.downloadFile(path: path, connection: connection, to: localURL)
    }
}
