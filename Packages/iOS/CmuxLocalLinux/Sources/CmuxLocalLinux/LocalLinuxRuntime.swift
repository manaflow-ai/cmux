public import Foundation
import os.lock

#if os(iOS) && canImport(CmuxIshBridge)
internal import CmuxIshBridge
#endif

/// Errors reported by the local Linux runtime.
public nonisolated enum LocalLinuxError: Error, Equatable, Sendable {
    /// The bundled rootfs archive was not found when an import was required.
    case rootfsAssetMissing
    /// The rootfs importer returned an error message.
    case rootfsImportFailed(String)
    /// The imported rootfs could not be made the active rootfs.
    case rootfsActivationFailed(String)
    /// Rootfs metadata or directory persistence failed.
    case rootfsPersistenceFailed(String)
    /// The kernel failed to boot. The value is the negative Linux errno.
    case bootFailed(errno: Int32)
    /// The kernel rejected a new terminal session. The value is the negative Linux errno.
    case sessionOpenFailed(errno: Int32)
    /// A session was requested before this runtime finished booting.
    case notBooted
    /// A command, environment entry, or init command cannot be represented as a C string.
    case invalidCommand
    /// Terminal dimensions must be positive and fit in iSH's 16-bit pty fields.
    case invalidDimensions
    /// A session operation was attempted after it was hung up.
    case closed
    /// The kernel rejected terminal input. The value is the negative Linux errno.
    case inputFailed(errno: Int32)
    /// The platform does not contain the iSH bridge.
    case kernelUnavailable
    /// The Ghostty renderer could not host the terminal surface.
    case rendererUnavailable
    /// The scrollback ring could not start consuming session output.
    case outputRetentionUnavailable
    /// The kernel reported a written byte count outside the submitted range.
    case inputByteCountInvalid
    /// An unexpected bridge or filesystem error occurred.
    case operationFailed(String)
}

/// Errors raised by a ``LocalLinuxKernelBridge`` implementation.
public nonisolated enum LocalLinuxKernelBridgeError: Error, Equatable, Sendable {
    /// Rootfs import failed and includes the bridge's diagnostic text.
    case rootfsImportFailed(String)
    /// Kernel boot failed with a negative Linux errno.
    case bootFailed(errno: Int32)
    /// Session creation failed with a negative Linux errno.
    case sessionOpenFailed(errno: Int32)
    /// This platform does not provide an iSH kernel implementation.
    case unavailable
}

/// Negative Linux errno values as returned across the iSH C ABI.
///
/// The shim reports failures as `-errno`, so every constant here is negative.
/// Only the values the Swift side produces or interprets are listed.
nonisolated enum LinuxErrno {
    /// `EIO`: a generic kernel I/O failure.
    static let eio: Int32 = -5
    /// `EAGAIN`: the tty input buffer is full, retry after a readiness edge.
    static let eagain: Int32 = -11
    /// `ENOMEM`: a host allocation failed before entering the kernel.
    static let enomem: Int32 = -12
    /// `EINVAL`: host-side validation rejected an argument.
    static let einval: Int32 = -22
}

/// Synchronous, C-facing operations needed by ``LocalLinuxRuntime``.
///
/// The runtime invokes these requirements from an actor or a detached
/// operation. Implementations must be safe to call from arbitrary threads and
/// must copy callback bytes before returning from the callback. The production
/// iSH implementation satisfies this contract by quiescing callbacks during
/// session hangup.
public nonisolated protocol LocalLinuxKernelBridge: Sendable {
    /// Imports an archive into a destination fakefs directory.
    /// - Parameters:
    ///   - archivePath: Absolute path to an Alpine `.tar.gz` archive.
    ///   - destinationPath: A new directory that the bridge may create.
    /// - Throws: ``LocalLinuxKernelBridgeError/rootfsImportFailed(_:)`` when
    ///   the importer rejects the archive.
    nonisolated func importRootfs(archivePath: String, destinationPath: String) throws

    /// Boots the process-global kernel against an imported fakefs.
    /// - Parameters:
    ///   - fakefsDataPath: Path to the imported fakefs data directory.
    ///   - initCommand: Optional init executable, or `nil` for the bridge default.
    /// - Throws: ``LocalLinuxKernelBridgeError/bootFailed(errno:)`` on failure.
    nonisolated func boot(fakefsDataPath: String, initCommand: String?) throws

    /// Opens a pty-backed process and reports its output, terminal end, and
    /// input-buffer readiness.
    ///
    /// A production bridge invokes `onTermination` exactly once for both
    /// natural process exit and explicit hangup, after its final output
    /// callback. `onInputReady` is a coalesced hint that the emulated process
    /// consumed input bytes or otherwise made room in its tty.
    /// - Parameters:
    ///   - command: Null-free argv entries, with the executable first.
    ///   - environment: Null-free `KEY=VALUE` entries.
    ///   - columns: Initial terminal width.
    ///   - rows: Initial terminal height.
    ///   - output: Receives an owned copy of each output chunk.
    ///   - onTermination: Invoked once when the pty can produce no more output.
    ///     It must not call a bridge operation synchronously; schedule teardown instead.
    ///   - onInputReady: Signals a non-blocking host waiter. It must not call
    ///     a bridge operation synchronously.
    /// - Returns: A thread-safe session handle.
    /// - Throws: ``LocalLinuxKernelBridgeError/sessionOpenFailed(errno:)`` on failure.
    nonisolated func openSession(
        command: [String],
        environment: [String],
        columns: Int32,
        rows: Int32,
        output: @escaping @Sendable (Data) -> Void,
        onTermination: @escaping @Sendable () -> Void,
        onInputReady: @escaping @Sendable () -> Void
    ) throws -> any LocalLinuxKernelSession
}

/// A thread-safe handle returned by ``LocalLinuxKernelBridge/openSession(command:environment:columns:rows:output:onTermination:onInputReady:)``.
public nonisolated protocol LocalLinuxKernelSession: Sendable {
    /// Writes bytes to the pty's input side.
    /// - Parameter data: Keyboard or paste bytes.
    /// - Returns: The number of bytes accepted, or a negative Linux errno.
    nonisolated func send(_ data: Data) -> Int

    /// Changes the pty window size.
    nonisolated func resize(columns: Int32, rows: Int32)

    /// Hangs up the pty and quiesces its output callback.
    ///
    /// Implementations must make this operation idempotent. It is called from
    /// both explicit session shutdown and deinitialization paths.
    nonisolated func hangup()
}

/// A filesystem seam used to test rootfs import and activation without disk I/O.
public nonisolated protocol LocalLinuxFileSystem: Sendable {
    /// Returns whether a path exists.
    nonisolated func fileExists(at url: URL) -> Bool

    /// Creates a directory and all missing parents.
    nonisolated func createDirectory(at url: URL) throws

    /// Removes a file or directory.
    nonisolated func removeItem(at url: URL) throws

    /// Moves a file or directory.
    nonisolated func moveItem(from sourceURL: URL, to destinationURL: URL) throws

    /// Writes bytes using an atomic replacement where supported.
    nonisolated func writeAtomically(_ data: Data, to url: URL) throws

    /// Reads bytes from a file.
    nonisolated func readData(at url: URL) throws -> Data
}

/// The production filesystem implementation backed by ``FileManager``.
public nonisolated struct LocalLinuxFileSystemClient: LocalLinuxFileSystem, Sendable {
    /// Creates a filesystem client. The client has no mutable state.
    public init() {}

    /// Checks whether a file or directory exists at `url`.
    public func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// Creates `url` and any missing parent directories.
    public func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    /// Removes the item at `url`.
    public func removeItem(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    /// Moves one filesystem item to `destinationURL`.
    public func moveItem(from sourceURL: URL, to destinationURL: URL) throws {
        try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
    }

    /// Writes `data` to `url` with Foundation's atomic option.
    public func writeAtomically(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic])
    }

    /// Reads all bytes at `url`.
    public func readData(at url: URL) throws -> Data {
        try Data(contentsOf: url)
    }
}

/// A closure-backed kernel bridge for unit tests and previews.
///
/// The default handlers succeed without starting a kernel. Tests can inject an
/// output callback from `openSession` and invoke it synchronously or later from
/// their own deterministic test driver.
public nonisolated struct LocalLinuxTestKernelBridge: LocalLinuxKernelBridge, Sendable {
    /// Signature for the rootfs import test hook.
    public typealias ImportRootfsHandler = @Sendable (String, String) throws -> Void
    /// Signature for the boot test hook.
    public typealias BootHandler = @Sendable (String, String?) throws -> Void
    /// Signature for the session-open test hook. The closure receives the
    /// command, environment, columns, rows, output callback, termination
    /// callback, and input-readiness callback in that order.
    public typealias OpenSessionHandler = @Sendable (
        [String],
        [String],
        Int32,
        Int32,
        @Sendable (Data) -> Void,
        @Sendable () -> Void,
        @Sendable () -> Void
    ) throws -> any LocalLinuxKernelSession

    private let importRootfsHandler: ImportRootfsHandler
    private let bootHandler: BootHandler
    private let openSessionHandler: OpenSessionHandler

    /// Creates a bridge with injectable handlers.
    /// - Parameters:
    ///   - importRootfs: Called for each rootfs import.
    ///   - boot: Called for each kernel boot.
    ///   - openSession: Called for each terminal session.
    public init(
        importRootfs: @escaping ImportRootfsHandler = { _, _ in },
        boot: @escaping BootHandler = { _, _ in },
        openSession: @escaping OpenSessionHandler = { _, _, _, _, _, _, _ in
            LocalLinuxTestKernelSession()
        }
    ) {
        self.importRootfsHandler = importRootfs
        self.bootHandler = boot
        self.openSessionHandler = openSession
    }

    /// Invokes the injected rootfs import hook.
    public func importRootfs(archivePath: String, destinationPath: String) throws {
        try importRootfsHandler(archivePath, destinationPath)
    }

    /// Invokes the injected boot hook.
    public func boot(fakefsDataPath: String, initCommand: String?) throws {
        try bootHandler(fakefsDataPath, initCommand)
    }

    /// Invokes the injected session hook.
    public func openSession(
        command: [String],
        environment: [String],
        columns: Int32,
        rows: Int32,
        output: @escaping @Sendable (Data) -> Void,
        onTermination: @escaping @Sendable () -> Void,
        onInputReady: @escaping @Sendable () -> Void
    ) throws -> any LocalLinuxKernelSession {
        try openSessionHandler(command, environment, columns, rows, output, onTermination, onInputReady)
    }
}

/// A closure-backed kernel session for unit tests.
public nonisolated struct LocalLinuxTestKernelSession: LocalLinuxKernelSession, Sendable {
    /// Signature for accepted-input test hooks.
    public typealias SendHandler = @Sendable (Data) -> Int
    /// Signature for resize test hooks.
    public typealias ResizeHandler = @Sendable (Int32, Int32) -> Void
    /// Signature for hangup test hooks.
    public typealias HangupHandler = @Sendable () -> Void

    private let sendHandler: SendHandler
    private let resizeHandler: ResizeHandler
    private let hangupHandler: HangupHandler

    /// Creates a test session with no-op lifecycle handlers.
    /// - Parameters:
    ///   - send: Returns accepted input bytes. Defaults to all bytes.
    ///   - resize: Records a resize operation. Defaults to no-op.
    ///   - hangup: Records a hangup operation. Defaults to no-op.
    public init(
        send: @escaping SendHandler = { $0.count },
        resize: @escaping ResizeHandler = { _, _ in },
        hangup: @escaping HangupHandler = {}
    ) {
        self.sendHandler = send
        self.resizeHandler = resize
        self.hangupHandler = hangup
    }

    /// Returns the number of bytes accepted by the injected send hook.
    public func send(_ data: Data) -> Int {
        sendHandler(data)
    }

    /// Invokes the injected resize hook.
    public func resize(columns: Int32, rows: Int32) {
        resizeHandler(columns, rows)
    }

    /// Invokes the injected hangup hook.
    public func hangup() {
        hangupHandler()
    }
}

/// Provenance of the bundled root filesystem archive, decoded from
/// `alpine-rootfs.json`.
///
/// The build script writes this manifest beside the archive. The runtime uses
/// only ``sha256`` to decide whether an installed Linux disk matches the
/// bundled image; the remaining fields exist for diagnostics and notices.
public nonisolated struct LocalLinuxRootfsManifest: Decodable, Equatable, Sendable {
    /// One Alpine package recorded in the archive's package database.
    public struct Package: Decodable, Equatable, Sendable {
        /// Alpine package name.
        public let name: String
        /// Alpine package version, including the release suffix.
        public let version: String
        /// SPDX license expression reported by Alpine.
        public let license: String
    }

    /// Human-readable archive format description.
    public let format: String
    /// Distribution version, for example `Alpine Linux 3.24.1`.
    public let version: String
    /// Emulated CPU architecture of the userland.
    public let architecture: String
    /// Where the archive was produced or downloaded from.
    public let source: String
    /// File name of the archive resource.
    public let archive: String
    /// Lowercase hex SHA-256 of the archive resource.
    public let sha256: String
    /// Packages installed in the archive.
    public let packages: [Package]
}

/// Owns one process-global iSH kernel and opens local terminal sessions.
///
/// Construct one instance at the app composition root and inject it into the
/// feature that owns local terminals. The iSH kernel itself is process-global,
/// so creating more than one runtime for the same process is unsupported by
/// the underlying C bridge even though this type has no global singleton. The
/// runtime serializes boot state, but it does not own controller-level session
/// replacement fences; a composition root should therefore share one
/// controller for a runtime instead of racing independent controllers.
public actor LocalLinuxRuntime {
    /// Default command used for a newly opened local terminal.
    public nonisolated static let defaultCommand = ["/bin/login", "-f", "root"]
    /// Default environment used for a newly opened local terminal.
    public nonisolated static let defaultEnvironment = [
        "TERM=xterm-256color",
        "HOME=/root",
        "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
    ]
    /// Layout schema of the on-device install. Increment when the marker or
    /// directory layout changes in a way an older app build cannot read.
    nonisolated static let rootfsSchemaVersion = "cmux-local-linux-rootfs-v2"

    // The C callback is copied into fixed-size chunks before it reaches the
    // AsyncStream. The stream is intentionally bounded so a detached shell
    // cannot grow memory without limit. If the consumer cannot keep up, the
    // ingress closes the pty and reports EOF rather than dropping bytes while
    // pretending the session remains healthy. This is the only place output
    // is chunked; bridges hand over each kernel write as one value.
    nonisolated static let outputChunkByteLimit = 64 * 1024
    private nonisolated static let outputBufferChunkCapacity = 64

    /// The install configuration fixed at construction. Paths are
    /// standardized so equivalent relative and absolute URLs compare equal.
    private struct InstallConfiguration: Sendable {
        let rootURL: URL
        let archiveURL: URL?
        let archiveDigest: String?
        let initCommand: String?

        var marker: Data {
            LocalLinuxRuntime.rootfsMarker(digest: archiveDigest)
        }
    }

    private let kernel: any LocalLinuxKernelBridge
    private let fileSystem: any LocalLinuxFileSystem
    private let configuration: InstallConfiguration
    private var bootTask: Task<Result<Void, LocalLinuxError>, Never>?
    private var booted = false
    private var bootFailure: LocalLinuxError?

    /// Creates a runtime with constructor-injected kernel and filesystem seams.
    /// - Parameters:
    ///   - kernel: The iSH bridge, or `nil` to select the platform default.
    ///   - fileSystem: Filesystem used for rootfs persistence.
    ///   - rootURL: Persistent fakefs root. It contains `data` and its sibling
    ///     `meta.db`, matching iSH's ``mount_root`` layout.
    ///   - rootfsArchiveURL: Bundled Alpine archive imported when no matching
    ///     install exists.
    ///   - rootfsArchiveDigest: SHA-256 of that archive, recorded in the install
    ///     marker. `nil` records the schema version alone.
    ///   - initCommand: Optional init executable passed to the bridge.
    public init(
        kernel: (any LocalLinuxKernelBridge)? = nil,
        fileSystem: any LocalLinuxFileSystem = LocalLinuxFileSystemClient(),
        rootURL: URL = LocalLinuxRuntime.defaultRootURL(),
        rootfsArchiveURL: URL? = LocalLinuxRuntime.bundledRootfsURL(),
        rootfsArchiveDigest: String? = LocalLinuxRuntime.bundledRootfsManifest()?.sha256,
        initCommand: String? = nil
    ) {
        self.kernel = kernel ?? Self.makeDefaultKernelBridge()
        self.fileSystem = fileSystem
        self.configuration = InstallConfiguration(
            rootURL: rootURL.standardizedFileURL,
            archiveURL: rootfsArchiveURL?.standardizedFileURL,
            archiveDigest: rootfsArchiveDigest?.lowercased(),
            initCommand: initCommand
        )
    }

    /// Returns the persistent root directory in the app's Application Support container.
    public nonisolated static func defaultRootURL() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("LocalLinux/alpine", isDirectory: true)
    }

    /// Returns the bundled Alpine archive, when package resources contain it.
    public nonisolated static func bundledRootfsURL() -> URL? {
        #if SWIFT_PACKAGE
        Bundle.module.url(forResource: "alpine-rootfs", withExtension: "tar.gz")
        #else
        nil
        #endif
    }

    /// Decodes the bundled archive manifest, or `nil` when the resource is
    /// missing or malformed. Unknown manifest keys are ignored.
    public nonisolated static func bundledRootfsManifest() -> LocalLinuxRootfsManifest? {
        #if SWIFT_PACKAGE
        guard let url = Bundle.module.url(forResource: "alpine-rootfs", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode(LocalLinuxRootfsManifest.self, from: data)
        #else
        return nil
        #endif
    }

    /// The `.rootfs-version` marker contents for an install made from an
    /// archive with `digest`. The schema version and the digest are joined by
    /// a newline so either change forces a fresh import.
    nonisolated static func rootfsMarker(digest: String?) -> Data {
        guard let digest, !digest.isEmpty else {
            return Data(rootfsSchemaVersion.utf8)
        }
        return Data("\(rootfsSchemaVersion)\n\(digest.lowercased())".utf8)
    }

    /// Boots the kernel once and imports the rootfs when needed.
    ///
    /// Concurrent callers share one in-flight boot operation. A failed boot is
    /// retained for this runtime instance, so callers do not repeatedly mutate
    /// a potentially partially initialized process-global kernel.
    /// - Throws: ``LocalLinuxError`` when persistence, import, or kernel boot fails.
    public func bootIfNeeded() async throws {
        try Task.checkCancellation()

        if let initCommand = configuration.initCommand,
           initCommand.isEmpty || initCommand.contains("\0") {
            throw LocalLinuxError.invalidCommand
        }
        if booted {
            return
        }
        if let bootFailure {
            throw bootFailure
        }

        let task: Task<Result<Void, LocalLinuxError>, Never>
        if let bootTask {
            task = bootTask
        } else {
            let configuration = self.configuration
            let kernel = self.kernel
            let fileSystem = self.fileSystem
            let newTask = Task.detached(priority: .userInitiated) {
                Self.performBoot(
                    configuration: configuration,
                    kernel: kernel,
                    fileSystem: fileSystem
                )
            }
            bootTask = newTask
            task = newTask
        }

        // Awaiting a detached task does not throw on caller cancellation. This
        // lets us settle the actor's boot state before reporting cancellation.
        let result = await task.value
        bootTask = nil
        switch result {
        case .success:
            booted = true
        case .failure(let error):
            bootFailure = error
        }

        try Task.checkCancellation()
        try result.get()
    }

    /// Opens one emulated pty after a successful ``bootIfNeeded()`` call.
    /// - Parameters:
    ///   - command: Null-free argv entries. The default starts `/bin/login` as root.
    ///   - environment: Null-free `KEY=VALUE` entries.
    ///   - columns: Initial terminal width.
    ///   - rows: Initial terminal height.
    /// - Returns: An actor-isolated session whose output stream is safe to consume concurrently.
    /// - Throws: ``LocalLinuxError/notBooted`` or a bridge/session error.
    public func openSession(
        command: [String] = LocalLinuxRuntime.defaultCommand,
        environment: [String] = LocalLinuxRuntime.defaultEnvironment,
        columns: Int,
        rows: Int
    ) async throws -> LocalLinuxSession {
        try Task.checkCancellation()
        guard booted else {
            if let bootFailure {
                throw bootFailure
            }
            throw LocalLinuxError.notBooted
        }
        guard !command.isEmpty,
              command.first.map({ !$0.isEmpty }) ?? false,
              command.allSatisfy({ !$0.contains("\0") }),
              environment.allSatisfy({ !$0.contains("\0") }) else {
            throw LocalLinuxError.invalidCommand
        }
        guard let columns32 = Int32(exactly: columns),
              let rows32 = Int32(exactly: rows),
              columns32 > 0,
              rows32 > 0,
              columns32 <= Int32(UInt16.max),
              rows32 <= Int32(UInt16.max) else {
            throw LocalLinuxError.invalidDimensions
        }

        let lifecycle = LocalLinuxSessionLifecycle()
        let ingress = LocalLinuxOutputIngress(
            lifecycle: lifecycle,
            chunkByteLimit: Self.outputChunkByteLimit,
            bufferChunkCapacity: Self.outputBufferChunkCapacity
        )
        let inputReadiness = LocalLinuxInputReadiness()
        let finish: @Sendable () -> Void = { [ingress, inputReadiness] in
            ingress.finishFromKernel()
            inputReadiness.finish()
        }
        let callback: @Sendable (Data) -> Void = { [ingress] data in
            ingress.receive(data)
        }
        let inputReady: @Sendable () -> Void = { [inputReadiness] in
            inputReadiness.signal()
        }
        let kernel = self.kernel
        let openTask = Task.detached(priority: .userInitiated) {
            Result {
                try kernel.openSession(
                    command: command,
                    environment: environment,
                    columns: columns32,
                    rows: rows32,
                    output: callback,
                    onTermination: finish,
                    onInputReady: inputReady
                )
            }.mapError { error in
                Self.mapBridgeError(error, operation: "session open")
            }
        }
        let result = await openTask.value
        switch result {
        case .failure(let error):
            // No successful handle exists on this path. The ingress still
            // closes its stream so a consumer cannot remain suspended while
            // the caller receives the bridge error.
            inputReadiness.finish()
            ingress.finishWithoutSession()
            // Cancellation owns the operation's outcome once the caller has
            // cancelled, even when the synchronous bridge reports a failure
            // at the same boundary. The stream has already been closed above.
            if Task.isCancelled {
                throw CancellationError()
            }
            throw error
        case .success(let kernelSession):
            // Construct the actor before attaching teardown. A synchronous
            // bridge can emit output, terminate, or overflow before returning;
            // the actor then observes that settled lifecycle state. Attaching
            // after construction also gives every cancellation path one owner
            // whose deinit can finish the handle if the task is cancelled in
            // this narrow window.
            let hangupGate = LocalLinuxSessionHangupGate(kernelSession: kernelSession)
            let session = LocalLinuxSession(
                kernelSession: kernelSession,
                output: ingress.stream,
                inputReady: inputReadiness.stream,
                lifecycle: lifecycle,
                ingress: ingress,
                inputReadiness: inputReadiness,
                hangupGate: hangupGate
            )
            ingress.attach(hangup: { _ = hangupGate.begin() })
            // Cancellation can arrive in the tiny window between the first
            // check and actor construction. Close the fully initialized actor
            // as well, so no successful handle escapes a cancelled request.
            if Task.isCancelled {
                await session.hangup()
                throw CancellationError()
            }
            return session
        }
    }

    private nonisolated static func makeDefaultKernelBridge() -> any LocalLinuxKernelBridge {
        #if os(iOS) && canImport(CmuxIshBridge)
        return IshLocalLinuxKernelBridge()
        #else
        return UnavailableLocalLinuxKernelBridge()
        #endif
    }

    // MARK: Boot stages

    /// Locations derived from one install root.
    private struct InstallLayout {
        let rootURL: URL
        let parentURL: URL
        let dataURL: URL
        let metadataURL: URL
        let markerURL: URL

        init(rootURL: URL) {
            self.rootURL = rootURL
            self.parentURL = rootURL.deletingLastPathComponent()
            self.dataURL = rootURL.appendingPathComponent("data", isDirectory: true)
            self.metadataURL = rootURL.appendingPathComponent("meta.db", isDirectory: false)
            self.markerURL = rootURL.appendingPathComponent(".rootfs-version", isDirectory: false)
        }
    }

    private nonisolated static func performBoot(
        configuration: InstallConfiguration,
        kernel: any LocalLinuxKernelBridge,
        fileSystem: any LocalLinuxFileSystem
    ) -> Result<Void, LocalLinuxError> {
        do {
            try prepareAndBoot(
                configuration: configuration,
                kernel: kernel,
                fileSystem: fileSystem
            )
            return .success(())
        } catch let error as LocalLinuxError {
            return .failure(error)
        } catch {
            return .failure(.operationFailed(String(describing: error)))
        }
    }

    /// Boots the installed Linux disk, or imports the bundled archive first.
    ///
    /// An install is reused only when its marker equals the bundled archive's
    /// marker. A different schema version or archive digest means the app now
    /// ships a different image; the runtime then replaces the on-device Linux
    /// disk with a fresh import of the bundled archive. Files created inside
    /// the old install are discarded with it after the new kernel boots.
    private nonisolated static func prepareAndBoot(
        configuration: InstallConfiguration,
        kernel: any LocalLinuxKernelBridge,
        fileSystem: any LocalLinuxFileSystem
    ) throws {
        let layout = InstallLayout(rootURL: configuration.rootURL)
        try persist("create root directory") {
            try fileSystem.createDirectory(at: layout.parentURL)
        }

        if try installMatchesBundle(layout: layout, marker: configuration.marker, fileSystem: fileSystem) {
            try bootKernel(kernel, layout: layout, configuration: configuration)
            return
        }

        guard let archiveURL = configuration.archiveURL,
              fileSystem.fileExists(at: archiveURL) else {
            throw LocalLinuxError.rootfsAssetMissing
        }
        try importAndActivate(
            archiveURL: archiveURL,
            layout: layout,
            configuration: configuration,
            kernel: kernel,
            fileSystem: fileSystem
        )
    }

    /// Reads the installed marker and compares it to the bundled marker.
    private nonisolated static func installMatchesBundle(
        layout: InstallLayout,
        marker: Data,
        fileSystem: any LocalLinuxFileSystem
    ) throws -> Bool {
        guard fileSystem.fileExists(at: layout.dataURL),
              fileSystem.fileExists(at: layout.metadataURL),
              fileSystem.fileExists(at: layout.markerURL) else {
            return false
        }
        let installed = try persist("read rootfs metadata") {
            try fileSystem.readData(at: layout.markerURL)
        }
        return installed == marker
    }

    private nonisolated static func bootKernel(
        _ kernel: any LocalLinuxKernelBridge,
        layout: InstallLayout,
        configuration: InstallConfiguration
    ) throws {
        try bridge("kernel boot") {
            try kernel.boot(
                fakefsDataPath: layout.dataURL.path,
                initCommand: configuration.initCommand
            )
        }
    }

    /// Imports the archive into a staging directory, swaps it in as the
    /// active root, boots, and then discards the previous install. Any failure
    /// restores the previous install and reports the original error.
    private nonisolated static func importAndActivate(
        archiveURL: URL,
        layout: InstallLayout,
        configuration: InstallConfiguration,
        kernel: any LocalLinuxKernelBridge,
        fileSystem: any LocalLinuxFileSystem
    ) throws {
        // Imports live beside the active root. The active root itself must be
        // replaced as one directory because fakefs_import creates both
        // `<root>/data` and `<root>/meta.db`; moving only `data` loses the DB.
        let stagingURL = layout.parentURL.appendingPathComponent(
            ".import-\(UUID().uuidString)",
            isDirectory: true
        )
        let staging = InstallLayout(rootURL: stagingURL)
        var oldRootBackupURL: URL?
        var activeRootWasReplaced = false

        func restore() {
            restoreRootfsAfterFailedActivation(
                fileSystem: fileSystem,
                rootURL: layout.rootURL,
                stagingURL: stagingURL,
                oldRootBackupURL: oldRootBackupURL,
                activeRootWasReplaced: activeRootWasReplaced
            )
        }

        do {
            try bridge("rootfs import", unexpected: LocalLinuxError.rootfsImportFailed) {
                // fakefs_import creates `<destination>/data` and its metadata
                // database itself. Passing the data child would make its first
                // mkdir target a missing parent and fail with ENOENT.
                try kernel.importRootfs(archivePath: archiveURL.path, destinationPath: stagingURL.path)
            }
            guard fileSystem.fileExists(at: staging.dataURL) else {
                throw LocalLinuxError.rootfsImportFailed("importer produced no data directory")
            }
            try fileSystem.writeAtomically(configuration.marker, to: staging.markerURL)

            if fileSystem.fileExists(at: layout.rootURL) {
                let backup = layout.parentURL.appendingPathComponent(
                    ".rootfs-backup-\(UUID().uuidString)",
                    isDirectory: true
                )
                try fileSystem.moveItem(from: layout.rootURL, to: backup)
                oldRootBackupURL = backup
            }

            // fakefs_import writes both `<root>/data` and `<root>/meta.db`.
            // Activate the whole imported root in one rename so mount_root's
            // `meta.db` lookup remains adjacent to its `data` directory.
            try fileSystem.moveItem(from: stagingURL, to: layout.rootURL)
            activeRootWasReplaced = true

            try bootKernel(kernel, layout: layout, configuration: configuration)

            // Keep backups until the new kernel has accepted the activated
            // rootfs. A boot failure can then restore the previous data.
            if let oldRootBackupURL {
                try? fileSystem.removeItem(at: oldRootBackupURL)
            }
            try? fileSystem.removeItem(at: stagingURL)
        } catch let error as LocalLinuxError {
            restore()
            throw error
        } catch {
            restore()
            throw LocalLinuxError.rootfsActivationFailed(error.localizedDescription)
        }
    }

    private nonisolated static func restoreRootfsAfterFailedActivation(
        fileSystem: any LocalLinuxFileSystem,
        rootURL: URL,
        stagingURL: URL,
        oldRootBackupURL: URL?,
        activeRootWasReplaced: Bool
    ) {
        // Best-effort recovery keeps a previously valid rootfs usable after a
        // failed move or boot. The original error remains the one reported.
        if fileSystem.fileExists(at: rootURL),
           activeRootWasReplaced || oldRootBackupURL != nil {
            try? fileSystem.removeItem(at: rootURL)
        }
        if let oldRootBackupURL,
           fileSystem.fileExists(at: oldRootBackupURL),
           !fileSystem.fileExists(at: rootURL) {
            try? fileSystem.moveItem(from: oldRootBackupURL, to: rootURL)
        }
        try? fileSystem.removeItem(at: stagingURL)
    }

    // MARK: Error mapping

    /// Runs a filesystem step and reports its failure as a persistence error.
    private nonisolated static func persist<T>(
        _ step: String,
        _ body: () throws -> T
    ) throws -> T {
        do {
            return try body()
        } catch let error as LocalLinuxError {
            throw error
        } catch {
            throw LocalLinuxError.rootfsPersistenceFailed("\(step): \(error.localizedDescription)")
        }
    }

    /// Runs a bridge call and maps its error into ``LocalLinuxError``.
    ///
    /// A bridge that already produced a ``LocalLinuxError`` is passed through.
    /// A ``LocalLinuxKernelBridgeError`` is translated case by case. Any other
    /// error becomes `unexpected(message)`, which defaults to
    /// ``LocalLinuxError/operationFailed(_:)`` prefixed with `operation`.
    private nonisolated static func bridge(
        _ operation: String,
        unexpected: ((String) -> LocalLinuxError)? = nil,
        _ body: () throws -> Void
    ) throws {
        do {
            try body()
        } catch {
            if let unexpected,
               !(error is LocalLinuxError),
               !(error is LocalLinuxKernelBridgeError) {
                throw unexpected(error.localizedDescription)
            }
            throw mapBridgeError(error, operation: operation)
        }
    }

    private nonisolated static func mapBridgeError(
        _ error: any Error,
        operation: String
    ) -> LocalLinuxError {
        if let error = error as? LocalLinuxError {
            return error
        }
        if let error = error as? LocalLinuxKernelBridgeError {
            switch error {
            case .rootfsImportFailed(let message):
                return .rootfsImportFailed(message)
            case .bootFailed(let errno):
                return .bootFailed(errno: errno)
            case .sessionOpenFailed(let errno):
                return .sessionOpenFailed(errno: errno)
            case .unavailable:
                return .kernelUnavailable
            }
        }
        return .operationFailed("\(operation): \(error.localizedDescription)")
    }
}

/// Synchronous lifecycle state shared by the C callback and the session actor.
///
/// `OSAllocatedUnfairLock` provides the one synchronous compare-and-set needed
/// by callbacks that can arrive on arbitrary iSH threads. The class is
/// `Sendable` because its only mutable state is the lock-protected bit.
private nonisolated final class LocalLinuxSessionLifecycle: Sendable {
    // A synchronous callback may race an actor teardown. This short-lived
    // one-shot gate is the sanctioned lock carve-out for that C callback seam.
    private let ended = OSAllocatedUnfairLock(initialState: false)

    /// Claims the end transition. Only the winner finishes the output stream.
    func markEnded() -> Bool {
        ended.withLock { value in
            guard !value else { return false }
            value = true
            return true
        }
    }

    /// Reads whether the pty has already emitted its terminal event.
    var hasEnded: Bool {
        ended.withLock { $0 }
    }
}

/// Serializes the one synchronous kernel-hangup operation for a session.
///
/// The iSH bridge has a synchronous C teardown call, but callers must not
/// block an actor (especially `MainActor`) while it runs. The gate starts that
/// call in one detached task and stores the task as the completion token. Every
/// caller receives the same token, so concurrent natural-exit, overflow, and
/// explicit-close paths perform one C call and can await its completion without
/// a condition variable or a blocked thread.
private nonisolated final class LocalLinuxSessionHangupGate: @unchecked Sendable {
    private struct State: Sendable {
        var hangupTask: Task<Void, Never>?
    }

    private let kernelSession: any LocalLinuxKernelSession
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(kernelSession: any LocalLinuxKernelSession) {
        self.kernelSession = kernelSession
    }

    /// Starts the kernel hangup at most once and returns its non-cancellable
    /// completion token. The C call runs off the caller's executor.
    @discardableResult
    func begin() -> Task<Void, Never> {
        state.withLock { state in
            if let hangupTask = state.hangupTask {
                return hangupTask
            }

            let kernelSession = self.kernelSession
            let hangupTask = Task.detached(priority: .utility) {
                kernelSession.hangup()
            }
            state.hangupTask = hangupTask
            return hangupTask
        }
    }

    /// Awaits the shared hangup operation without blocking an executor.
    func complete() async {
        await begin().value
    }
}

/// Coalesces tty-consumption notifications for one input worker.
///
/// The C callback can run on any iSH task thread and may race stream teardown.
/// A one-element `bufferingNewest` stream preserves a readiness edge without
/// retaining one event per consumed byte. The continuation is never used to
/// perform a bridge operation synchronously.
private nonisolated final class LocalLinuxInputReadiness: Sendable {
    private struct State: Sendable {
        var finished = false
    }

    let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let state = OSAllocatedUnfairLock(initialState: State())

    init() {
        let streamAndContinuation = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        self.stream = streamAndContinuation.stream
        self.continuation = streamAndContinuation.continuation
    }

    /// Signals one coalesced readiness edge.
    func signal() {
        guard state.withLock({ !$0.finished }) else { return }
        _ = continuation.yield(())
    }

    /// Finishes the waiter so an input worker cannot remain suspended at exit.
    func finish() {
        let shouldFinish = state.withLock { state in
            guard !state.finished else { return false }
            state.finished = true
            return true
        }
        if shouldFinish {
            continuation.finish()
        }
    }
}

/// Bounded ingress between an arbitrary kernel callback thread and Swift
/// consumers. The ingress owns the stream continuation from creation, so
/// overflow and cancellation are handled even if they happen before the
/// actor session has been initialized.
///
/// Vocabulary: `finish*` closes the output stream for one specific reason.
/// `startPendingHangup*` performs the one-shot kernel hangup that a finish
/// may have requested, either on the calling thread or on a detached task
/// when the caller is a kernel callback that must not re-enter the shim.
private nonisolated final class LocalLinuxOutputIngress: Sendable {
    private enum OfferResult {
        case enqueued
        case stopped
        case overflow
    }

    private struct State: Sendable {
        var didFinish = false
        var needsHangup = false
        var hangupStarted = false
        var hangup: (@Sendable () -> Void)?
    }

    let stream: AsyncStream<Data>
    let continuation: AsyncStream<Data>.Continuation

    private let lifecycle: LocalLinuxSessionLifecycle
    private let chunkByteLimit: Int
    // This lock is limited to short compare-and-set transitions made by C
    // callbacks. The stream itself remains the asynchronous ownership seam.
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(
        lifecycle: LocalLinuxSessionLifecycle,
        chunkByteLimit: Int,
        bufferChunkCapacity: Int
    ) {
        let streamAndContinuation = AsyncStream<Data>.makeStream(
            bufferingPolicy: .bufferingOldest(max(1, bufferChunkCapacity))
        )
        self.stream = streamAndContinuation.stream
        self.continuation = streamAndContinuation.continuation
        self.lifecycle = lifecycle
        self.chunkByteLimit = max(1, chunkByteLimit)
        self.continuation.onTermination = { @Sendable [weak self] _ in
            self?.consumerTerminated()
        }
    }

    /// Offers one bridge-owned data value as bounded stream chunks.
    func receive(_ data: Data) {
        guard !data.isEmpty else { return }
        data.withUnsafeBytes { (rawBuffer: UnsafeRawBufferPointer) in
            guard let baseAddress = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                return
            }

            var offset = 0
            while offset < rawBuffer.count {
                let count = min(chunkByteLimit, rawBuffer.count - offset)
                let chunk = Data(
                    bytes: baseAddress.advanced(by: offset),
                    count: count
                )
                switch offer(chunk) {
                case .enqueued:
                    offset += count
                case .stopped:
                    return
                case .overflow:
                    finishForOverflow()
                    return
                }
            }
        }
    }

    /// Closes the stream for a natural pty exit. Kernel cleanup is deferred
    /// off the callback thread, because the bridge forbids synchronous
    /// callback re-entry while the terminal event is being delivered.
    func finishFromKernel() {
        finish(needsHangup: true, deferHangup: true)
    }

    /// Closes the stream when opening failed before a usable session handle
    /// existed. Any pending hangup request remains harmless and cannot invoke
    /// a missing handle.
    func finishWithoutSession() {
        finish(needsHangup: false, deferHangup: false)
    }

    /// Closes the stream for a host-requested hangup from a safe actor or
    /// worker thread, and starts the detached hangup operation. The call itself
    /// does not block.
    func finishForHangup() {
        let result = state.withLock { state -> (shouldFinish: Bool, hangup: (@Sendable () -> Void)?) in
            state.needsHangup = true
            guard !state.didFinish else { return (false, nil) }
            state.didFinish = true
            guard !state.hangupStarted, let hangup = state.hangup else {
                return (true, nil)
            }
            state.hangupStarted = true
            state.hangup = nil
            return (true, hangup)
        }
        _ = lifecycle.markEnded()
        if result.shouldFinish {
            continuation.finish()
        }
        // Claim the operation before finishing the stream. AsyncStream may
        // invoke onTermination synchronously; claiming first prevents that
        // callback from replacing the detached close request with another one.
        result.hangup?()
    }

    /// Closes the stream for a host-requested hangup from a deinitializer or
    /// callback-adjacent context. The iSH shim forbids calling back into C
    /// synchronously from an output callback, so the one-shot hangup is
    /// scheduled after the state transition instead of running on the
    /// releasing thread.
    func finishForHangupDeferred() {
        finish(needsHangup: true, deferHangup: true)
    }

    /// Installs the one-shot hangup operation after the bridge returns a
    /// session. If overflow or stream cancellation happened first, invoke it
    /// immediately outside the state lock.
    func attach(hangup: @escaping @Sendable () -> Void) {
        let pendingHangup = state.withLock { state -> (@Sendable () -> Void)? in
            // Natural termination can be delivered synchronously from inside
            // `openSession`, before the bridge returns its handle. In that
            // case no teardown closure is needed, and retaining the handle
            // here would create an ingress -> handle -> callback -> ingress
            // cycle forever.
            guard !state.hangupStarted,
                  !state.didFinish || state.needsHangup else {
                return nil
            }
            if state.hangup == nil {
                state.hangup = hangup
            }
            guard state.needsHangup, let installed = state.hangup else {
                return nil
            }
            state.hangupStarted = true
            // Do not retain the kernel session after handing the closure to
            // the caller. This breaks the strong cycle even if C re-enters
            // Swift while the hangup operation is in progress.
            state.hangup = nil
            return installed
        }
        pendingHangup?()
    }

    /// Performs the requested one-shot hangup on the calling thread. This
    /// method is safe to call repeatedly.
    func startPendingHangup() {
        if let hangup = takeHangup() {
            hangup()
        }
    }

    /// Performs the requested one-shot hangup on a detached task. Used from a
    /// stream callback or deinitializer, where synchronous re-entry into the C
    /// shim is forbidden.
    private func startPendingHangupDeferred() {
        guard let hangup = takeHangup() else { return }
        Task.detached(priority: .utility) {
            hangup()
        }
    }

    /// Claims and clears the teardown closure before invoking it. Clearing it
    /// while holding the state lock breaks the ingress/handle retain cycle even
    /// when the deferred task is delayed by scheduler pressure.
    private func takeHangup() -> (@Sendable () -> Void)? {
        state.withLock { state in
            guard state.needsHangup, !state.hangupStarted,
                  let hangup = state.hangup else {
                return nil
            }
            state.hangupStarted = true
            state.hangup = nil
            return hangup
        }
    }

    private func offer(_ chunk: Data) -> OfferResult {
        let canYield = state.withLock { !$0.didFinish }
        guard canYield else { return .stopped }

        switch continuation.yield(chunk) {
        case .enqueued:
            // A finish can race the yield. The continuation decides the
            // ordering; this check prevents more chunks after a known end.
            return state.withLock { $0.didFinish ? .stopped : .enqueued }
        case .dropped, .terminated:
            let becameOverflow = state.withLock { state in
                guard !state.didFinish else { return false }
                state.didFinish = true
                state.needsHangup = true
                return true
            }
            return becameOverflow ? .overflow : .stopped
        @unknown default:
            let becameOverflow = state.withLock { state in
                guard !state.didFinish else { return false }
                state.didFinish = true
                state.needsHangup = true
                return true
            }
            return becameOverflow ? .overflow : .stopped
        }
    }

    private func finishForOverflow() {
        _ = lifecycle.markEnded()
        continuation.finish()
        // `finish()` may synchronously invoke `onTermination`; both paths use
        // the same one-shot gate, and neither calls C on this callback stack.
        startPendingHangupDeferred()
    }

    private func finish(needsHangup: Bool, deferHangup: Bool) {
        let shouldFinish = state.withLock { state in
            if needsHangup {
                state.needsHangup = true
            }
            // If this is a natural or pre-handle failure, discard any closure
            // that might have been installed by a racing bridge callback. A
            // closure is retained only while explicit teardown is required.
            if !state.needsHangup {
                state.hangup = nil
            }
            guard !state.didFinish else { return false }
            state.didFinish = true
            return true
        }
        _ = lifecycle.markEnded()
        if shouldFinish {
            continuation.finish()
        }
        guard needsHangup else { return }
        if deferHangup {
            startPendingHangupDeferred()
        } else {
            startPendingHangup()
        }
    }

    private func consumerTerminated() {
        let needsDeferredHangup = state.withLock { state in
            if !state.didFinish {
                state.didFinish = true
                state.needsHangup = true
                return true
            }
            return state.needsHangup
        }
        guard needsDeferredHangup else { return }
        _ = lifecycle.markEnded()
        startPendingHangupDeferred()
    }
}

/// One actor-isolated emulated pty and its session leader.
public actor LocalLinuxSession {
    /// Raw slave-side output bytes in write order. The stream finishes on hangup.
    public nonisolated let output: AsyncStream<Data>
    /// Coalesced notifications that the emulated process consumed tty input.
    /// A sender should await the next element before retrying a zero-byte write.
    public nonisolated let inputReady: AsyncStream<Void>

    /// Whether the pty has reached its terminal end. Natural process exit and
    /// explicit ``hangup()`` share this state, so session owners can
    /// distinguish an exhausted output stream from a temporary lane detach.
    public var isEnded: Bool {
        closed || lifecycle.hasEnded
    }

    private nonisolated let kernelSession: any LocalLinuxKernelSession
    private nonisolated let lifecycle: LocalLinuxSessionLifecycle
    private nonisolated let ingress: LocalLinuxOutputIngress
    private nonisolated let inputReadiness: LocalLinuxInputReadiness
    private nonisolated let hangupGate: LocalLinuxSessionHangupGate
    private var closed = false

    fileprivate init(
        kernelSession: any LocalLinuxKernelSession,
        output: AsyncStream<Data>,
        inputReady: AsyncStream<Void>,
        lifecycle: LocalLinuxSessionLifecycle,
        ingress: LocalLinuxOutputIngress,
        inputReadiness: LocalLinuxInputReadiness,
        hangupGate: LocalLinuxSessionHangupGate
    ) {
        self.kernelSession = kernelSession
        self.output = output
        self.inputReady = inputReady
        self.lifecycle = lifecycle
        self.ingress = ingress
        self.inputReadiness = inputReadiness
        self.hangupGate = hangupGate
        self.closed = lifecycle.hasEnded
    }

    /// Sends keyboard or paste bytes to the local terminal.
    /// - Parameter data: Input bytes to write.
    /// - Returns: Bytes accepted by the pty.
    /// - Throws: ``LocalLinuxError/closed``, ``LocalLinuxError/inputFailed(errno:)``,
    ///   or ``LocalLinuxError/inputByteCountInvalid`` for a bridge that reports
    ///   more accepted bytes than it received.
    @discardableResult
    public func send(_ data: Data) async throws -> Int {
        try Task.checkCancellation()
        guard !closed, !lifecycle.hasEnded else { throw LocalLinuxError.closed }
        guard !data.isEmpty else { return 0 }
        let accepted = kernelSession.send(data)
        guard !lifecycle.hasEnded else { throw LocalLinuxError.closed }
        guard accepted >= 0 else {
            throw LocalLinuxError.inputFailed(errno: Int32(clamping: accepted))
        }
        guard accepted <= data.count else {
            // A bridge must never report more bytes than it received. Treat a
            // broken implementation as a terminal failure so a caller cannot
            // advance its input cursor past unsent bytes.
            throw LocalLinuxError.inputByteCountInvalid
        }
        return accepted
    }

    /// Updates the terminal dimensions and sends SIGWINCH to the foreground process.
    /// - Parameters:
    ///   - columns: Positive terminal width.
    ///   - rows: Positive terminal height.
    /// - Throws: ``LocalLinuxError/closed`` or ``LocalLinuxError/invalidDimensions``.
    public func resize(columns: Int, rows: Int) async throws {
        try Task.checkCancellation()
        guard !closed, !lifecycle.hasEnded else { throw LocalLinuxError.closed }
        guard let columns32 = Int32(exactly: columns),
              let rows32 = Int32(exactly: rows),
              columns32 > 0,
              rows32 > 0,
              columns32 <= Int32(UInt16.max),
              rows32 <= Int32(UInt16.max) else {
            throw LocalLinuxError.invalidDimensions
        }
        kernelSession.resize(columns: columns32, rows: rows32)
        guard !lifecycle.hasEnded else { throw LocalLinuxError.closed }
    }

    /// Hangs up the pty, quiesces C callbacks, and finishes ``output``.
    public func hangup() async {
        guard !closed else {
            // A previous caller may still be completing the C fence on a
            // detached worker. Preserve the completion guarantee for repeated
            // hangups without blocking this actor.
            ingress.startPendingHangup()
            await hangupGate.complete()
            return
        }
        closed = true
        inputReadiness.finish()
        ingress.finishForHangup()
        ingress.startPendingHangup()
        // Wait even when an earlier overflow path already claimed the
        // deferred teardown closure.
        await hangupGate.complete()
    }

    /// Starts closing the underlying pty without an actor hop.
    ///
    /// The returned task is a completion fence. Callers that run on an actor
    /// should retain and await it before opening a replacement pty. This
    /// method is intentionally nonblocking, so a synchronous UI teardown can
    /// publish its state change without waiting on the C bridge.
    @discardableResult
    public nonisolated func beginClose() -> Task<Void, Never> {
        inputReadiness.finish()
        ingress.finishForHangup()
        // `finishForHangup()` may find a deferred overflow hangup already in
        // flight. The gate returns its shared task, so callers can safely
        // retain a completion fence without blocking the releasing thread.
        return hangupGate.begin()
    }

    deinit {
        // The bridge contract makes hangup synchronous and idempotent. Start
        // cleanup for sessions dropped without consuming their output stream.
        // Both the ingress callback and the gate use detached work, so the C
        // call cannot re-enter an iSH callback's releasing thread.
        inputReadiness.finish()
        ingress.finishForHangupDeferred()
        _ = hangupGate.begin()
    }
}

#if os(iOS) && canImport(CmuxIshBridge)

/// Production bridge that adapts the vendored iSH C shim to Swift values.
public nonisolated struct IshLocalLinuxKernelBridge: LocalLinuxKernelBridge, Sendable {
    /// Creates the stateless iSH bridge.
    public init() {}

    /// Imports an Alpine archive through the iSH fakefs converter.
    public func importRootfs(archivePath: String, destinationPath: String) throws {
        guard !archivePath.isEmpty,
              !destinationPath.isEmpty,
              !archivePath.contains("\0"),
              !destinationPath.contains("\0") else {
            throw LocalLinuxKernelBridgeError.rootfsImportFailed("invalid rootfs path")
        }
        var errorBuffer = [CChar](repeating: 0, count: 2048)
        let imported = archivePath.withCString { archiveCString in
            destinationPath.withCString { destinationCString in
                cmux_ish_import_rootfs(
                    archiveCString,
                    destinationCString,
                    &errorBuffer,
                    errorBuffer.count
                )
            }
        }
        guard imported else {
            let message = Self.decodeErrorBuffer(errorBuffer)
            throw LocalLinuxKernelBridgeError.rootfsImportFailed(
                message.isEmpty ? "iSH rootfs importer failed" : message
            )
        }
    }

    /// Boots iSH against the supplied fakefs data directory.
    public func boot(fakefsDataPath: String, initCommand: String?) throws {
        guard !fakefsDataPath.isEmpty,
              !fakefsDataPath.contains("\0"),
              initCommand.map({ !$0.isEmpty && !$0.contains("\0") }) ?? true else {
            throw LocalLinuxKernelBridgeError.bootFailed(errno: LinuxErrno.einval)
        }
        let result: Int32 = fakefsDataPath.withCString { fakefsCString in
            guard let initCommand else {
                return Int32(cmux_ish_boot(fakefsCString, nil))
            }
            return initCommand.withCString { initCString in
                Int32(cmux_ish_boot(fakefsCString, initCString))
            }
        }
        guard result == 0 else {
            throw LocalLinuxKernelBridgeError.bootFailed(errno: result)
        }
    }

    /// Opens a pty and forwards terminal-end and tty-readiness callbacks.
    public func openSession(
        command: [String],
        environment: [String],
        columns: Int32,
        rows: Int32,
        output: @escaping @Sendable (Data) -> Void,
        onTermination: @escaping @Sendable () -> Void,
        onInputReady: @escaping @Sendable () -> Void
    ) throws -> any LocalLinuxKernelSession {
        guard let executable = command.first,
              !executable.isEmpty,
              command.allSatisfy({ !$0.contains("\0") }),
              environment.allSatisfy({ !$0.contains("\0") }),
              columns > 0,
              rows > 0,
              columns <= Int32(UInt16.max),
              rows <= Int32(UInt16.max) else {
            // Keep direct bridge callers on the same validation path as the
            // actor runtime.
            throw LocalLinuxKernelBridgeError.sessionOpenFailed(errno: LinuxErrno.einval)
        }
        let callbackBox = IshCallbackContext(
            output: output,
            onTermination: onTermination,
            onInputReady: onInputReady
        )
        // The C shim owns this retain until it emits the terminal callback or
        // `cmux_ish_session_hangup` returns. `callbackBox` keeps the object
        // alive for a later Swift-side hangup race after natural exit. Both C
        // callbacks share the one retained context.
        let context = Unmanaged.passRetained(callbackBox).toOpaque()
        let handle: Int32
        do {
            handle = try Self.withCStringArray(command) { argv in
                try Self.withCStringArray(environment) { envp in
                    Int32(
                        cmux_ish_session_open(
                            argv,
                            envp,
                            columns,
                            rows,
                            Self.outputCallback,
                            context,
                            Self.inputReadyCallback,
                            context
                        )
                    )
                }
            }
        } catch {
            // CString allocation can fail before the C open call. There is no
            // terminal callback on that path, so release the retain explicitly.
            callbackBox.releaseRetainedContext(context)
            throw error
        }
        guard handle >= 0 else {
            callbackBox.releaseRetainedContext(context)
            throw LocalLinuxKernelBridgeError.sessionOpenFailed(errno: handle)
        }
        return IshLocalLinuxKernelSession(
            handle: handle,
            callbackContext: context,
            callbackBox: callbackBox
        )
    }

    private static let outputCallback: @convention(c) (
        UnsafeMutableRawPointer?,
        UnsafePointer<CChar>?,
        Int
    ) -> Void = { context, bytes, length in
        guard let context else { return }
        // Retain around the trampoline. The C-owned retain may be released by
        // a natural-end callback while this callback is still executing.
        let callbackBox = Unmanaged<IshCallbackContext>.fromOpaque(context)
            .retain()
            .takeRetainedValue()
        callbackBox.receive(context: context, bytes: bytes, length: length)
    }

    private static let inputReadyCallback: @convention(c) (
        UnsafeMutableRawPointer?
    ) -> Void = { context in
        guard let context else { return }
        // Retain around the trampoline. The C-owned retain can be released by
        // a concurrent terminal callback while this readiness edge is queued.
        let callbackBox = Unmanaged<IshCallbackContext>.fromOpaque(context)
            .retain()
            .takeRetainedValue()
        callbackBox.signalInputReady()
    }

    private static func decodeErrorBuffer(_ buffer: [CChar]) -> String {
        let bytes = buffer.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }

    /// Builds a temporary NULL-terminated argv/envp buffer for the C shim.
    private static func withCStringArray<R>(
        _ strings: [String],
        _ body: (UnsafePointer<UnsafePointer<CChar>?>) throws -> R
    ) throws -> R {
        var allocations: [UnsafeMutablePointer<CChar>] = []
        allocations.reserveCapacity(strings.count)
        defer {
            for pointer in allocations {
                free(pointer)
            }
        }
        for string in strings {
            guard let pointer = strdup(string) else {
                throw LocalLinuxKernelBridgeError.sessionOpenFailed(errno: LinuxErrno.enomem)
            }
            allocations.append(pointer)
        }

        var pointers: [UnsafePointer<CChar>?] = allocations.map { UnsafePointer($0) }
        pointers.append(nil)
        return try pointers.withUnsafeBufferPointer { buffer in
            // The appended NULL guarantees a non-empty buffer, including for
            // an explicitly empty environment vector.
            try body(buffer.baseAddress!)
        }
    }
}

/// Callback context retained by the C shim for one session lifetime.
private nonisolated final class IshCallbackContext: Sendable {
    private struct State: Sendable {
        var didTerminate = false
        var didReleaseRetainedContext = false
    }

    private let output: @Sendable (Data) -> Void
    private let onTermination: @Sendable () -> Void
    private let onInputReady: @Sendable () -> Void
    // C can deliver the terminal event while Swift teardown runs. This
    // synchronous gate protects the two one-shot transitions at that ABI seam.
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(
        output: @escaping @Sendable (Data) -> Void,
        onTermination: @escaping @Sendable () -> Void,
        onInputReady: @escaping @Sendable () -> Void
    ) {
        self.output = output
        self.onTermination = onTermination
        self.onInputReady = onInputReady
    }

    /// Handles one C callback. A `nil, 0` pair is the one-shot end marker.
    func receive(
        context: UnsafeMutableRawPointer,
        bytes: UnsafePointer<CChar>?,
        length: Int
    ) {
        if bytes == nil, length == 0 {
            let firstEnd = state.withLock { state in
                guard !state.didTerminate else { return false }
                state.didTerminate = true
                return true
            }
            if firstEnd {
                onTermination()
            }
            // The C-owned retain must be released exactly once. This can race
            // an explicit Swift hangup, which uses the same compare/exchange.
            releaseRetainedContext(context)
            return
        }
        guard let bytes, length > 0, !hasTerminated else {
            return
        }
        // One kernel write becomes one owned value. The runtime's ingress
        // splits it into bounded chunks; splitting here as well would copy
        // every byte twice.
        output(Data(bytes: bytes, count: length))
    }

    /// Reads the terminal state before forwarding a data callback.
    private var hasTerminated: Bool {
        state.withLock { $0.didTerminate }
    }

    /// Forwards a coalesced tty-readiness edge without touching the C bridge.
    func signalInputReady() {
        guard !hasTerminated else { return }
        onInputReady()
    }

    /// Releases the retain created by `Unmanaged.passRetained` exactly once.
    func releaseRetainedContext(_ context: UnsafeMutableRawPointer) {
        let firstRelease = state.withLock { state in
            guard !state.didReleaseRetainedContext else { return false }
            state.didReleaseRetainedContext = true
            return true
        }
        guard firstRelease else { return }
        Unmanaged<IshCallbackContext>.fromOpaque(context).release()
    }
}

/// Owns the C handle and callback retain for one iSH session.
///
/// `@unchecked Sendable` is required because Swift does not mark opaque C
/// pointers sendable. The handle and callback pointer never change, and the
/// lock protects only the one-shot close transition. `cmux_ish_session_hangup`
/// quiesces callbacks before the retained context is released. The lifetime
/// object is held by every operation that can close the handle, so its storage
/// remains valid while a detached deinit cleanup runs.
private nonisolated final class IshSessionLifetime: @unchecked Sendable {
    private let handle: Int32
    private let callbackContext: UnsafeMutableRawPointer
    private let callbackBox: IshCallbackContext
    // Several synchronous teardown paths can race, including callback-thread
    // deinit and an actor's explicit hangup. This is the sanctioned one-shot
    // callback lock carve-out, not a general session-state lock.
    private let didHangup = OSAllocatedUnfairLock(initialState: false)

    init(
        handle: Int32,
        callbackContext: UnsafeMutableRawPointer,
        callbackBox: IshCallbackContext
    ) {
        self.handle = handle
        self.callbackContext = callbackContext
        self.callbackBox = callbackBox
    }

    /// Returns the immutable handle for non-teardown tty operations.
    var handleForOperations: Int32 { handle }

    /// Hangs up the C session and releases its retained callback context once.
    func hangup() {
        let firstHangup = didHangup.withLock { value in
            guard !value else { return false }
            value = true
            return true
        }
        guard firstHangup else { return }
        cmux_ish_session_hangup(handle)
        // The C shim guarantees no callback is in flight after hangup returns.
        callbackBox.releaseRetainedContext(callbackContext)
    }
}

/// Thread-safe value wrapper for one opaque C session handle.
private nonisolated final class IshLocalLinuxKernelSession: LocalLinuxKernelSession, @unchecked Sendable {
    private let lifetime: IshSessionLifetime

    init(
        handle: Int32,
        callbackContext: UnsafeMutableRawPointer,
        callbackBox: IshCallbackContext
    ) {
        self.lifetime = IshSessionLifetime(
            handle: handle,
            callbackContext: callbackContext,
            callbackBox: callbackBox
        )
    }

    private var handle: Int32 {
        // The lifetime intentionally keeps the handle private. Input and
        // resize are only valid while this wrapper owns it; expose a read-only
        // accessor to the C calls below without duplicating mutable state.
        lifetime.handleForOperations
    }

    func send(_ data: Data) -> Int {
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.bindMemory(to: CChar.self).baseAddress else {
                return 0
            }
            return Int(cmux_ish_session_input(handle, baseAddress, rawBuffer.count))
        }
    }

    func resize(columns: Int32, rows: Int32) {
        cmux_ish_session_resize(handle, columns, rows)
    }

    func hangup() {
        lifetime.hangup()
    }

    deinit {
        // A final release can happen on an iSH output callback thread. Defer
        // C teardown so that callback never re-enters the shim synchronously.
        let lifetime = self.lifetime
        Task.detached(priority: .utility) {
            lifetime.hangup()
        }
    }
}

#else

/// Fallback bridge used when a host build does not include the iSH framework.
public nonisolated struct UnavailableLocalLinuxKernelBridge: LocalLinuxKernelBridge, Sendable {
    /// Creates an unavailable bridge.
    public init() {}

    /// Reports that rootfs import is unavailable on this platform.
    public func importRootfs(archivePath: String, destinationPath: String) throws {
        throw LocalLinuxKernelBridgeError.unavailable
    }

    /// Reports that kernel boot is unavailable on this platform.
    public func boot(fakefsDataPath: String, initCommand: String?) throws {
        throw LocalLinuxKernelBridgeError.unavailable
    }

    /// Reports that session creation is unavailable on this platform.
    public func openSession(
        command: [String],
        environment: [String],
        columns: Int32,
        rows: Int32,
        output: @escaping @Sendable (Data) -> Void,
        onTermination: @escaping @Sendable () -> Void,
        onInputReady: @escaping @Sendable () -> Void
    ) throws -> any LocalLinuxKernelSession {
        throw LocalLinuxKernelBridgeError.unavailable
    }
}

#endif
