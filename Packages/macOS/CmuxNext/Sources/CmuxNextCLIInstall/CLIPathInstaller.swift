import CmuxNextWakeups
public import Foundation

/// Install cmux CLI in PATH: a symlink at /usr/local/bin/cmux to the bundled
/// CLI (Contents/Resources/bin/cmux), as the old app made it. When the user
/// cannot write /usr/local/bin, the same commands run once more through an
/// administrator prompt (osascript `with administrator privileges`).
public nonisolated struct CLIPathInstaller: Sendable {
    /// What ``install(replacing:)`` did.
    public nonisolated struct InstallOutcome: Equatable, Sendable {
        /// The link was made through the administrator prompt.
        public let usedAdministratorPrivileges: Bool
        /// The link made, such as `/usr/local/bin/cmux`.
        public let destination: URL
        /// The bundled CLI it points to.
        public let source: URL
        /// What was at the destination before, when the caller chose to
        /// replace something that was not this app's link.
        public var replaced: Replaced? = nil
    }

    /// An entry at the destination that was not this app's link.
    public nonisolated enum Replaced: Equatable, Sendable {
        /// A symlink, with its target as written.
        case link(target: String)
        /// A file or other non-link entry.
        case file
    }

    /// What ``uninstall()`` did.
    public nonisolated struct UninstallOutcome: Equatable, Sendable {
        /// The entry was removed through the administrator prompt.
        public let usedAdministratorPrivileges: Bool
        /// The path uninstalled.
        public let destination: URL
        /// Something was there to remove.
        public let removedExistingEntry: Bool
    }

    /// The command name to install. `cmux-next` never shadows another
    /// app's `cmux`.
    public nonisolated enum Name: String, Sendable, CaseIterable {
        /// `/usr/local/bin/cmux`.
        case cmux
        /// `/usr/local/bin/cmux-next`.
        case cmuxNext = "cmux-next"

        /// The link's path in `/usr/local/bin`.
        public var destination: URL { URL(fileURLWithPath: "/usr/local/bin").appendingPathComponent(rawValue) }
    }

    /// Why an install or uninstall did not finish.
    public nonisolated enum Failure: Error, Equatable {
        /// No CLI at `path` in the app bundle.
        case bundledCLIMissing(path: String)
        /// Another app's CLI (a link elsewhere) or a file is at `path`;
        /// install replaces it only when asked to (`replacing: true`).
        case occupied(path: String, existing: Replaced)
        /// The link's folder, `path`, is a file.
        case destinationParentNotDirectory(path: String)
        /// A folder is at the link's `path`; it is never removed.
        case destinationIsDirectory(path: String)
        /// The link at `path` does not point to the bundled CLI afterwards.
        case installVerificationFailed(path: String)
        /// Something is still at `path` after removing it.
        case uninstallVerificationFailed(path: String)
        /// The administrator prompt was refused or its command failed.
        case privilegedCommandFailed(message: String)
    }

    /// Runs a shell command as administrator; throws `privilegedCommandFailed`.
    public typealias Privileged = @Sendable (_ command: String) async throws -> Void

    /// Where the link goes.
    public let destination: URL
    /// The bundled CLI the link points to.
    public let source: URL
    let privileged: Privileged

    /// An installer for one link.
    ///
    /// - Parameter destination: The link's path; `cmux` in `/usr/local/bin` by default.
    /// - Parameter source: The CLI to link to; this app's bundled CLI by default.
    /// - Parameter privileged: Runs a shell command as administrator when a direct write is refused;
    ///   tests pass a stand-in.
    public init(destination: URL = Name.cmux.destination,
                source: URL = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/bin/cmux"),
                privileged: @escaping Privileged = CLIPathInstaller.runAsAdministrator) {
        self.destination = destination
        self.source = source.standardizedFileURL
        self.privileged = privileged
    }

    /// Links the destination to this app's CLI. Anything there that is not
    /// already this app's link is refused (`Failure.occupied`) unless
    /// `replacing` is true, so another app's `cmux` never disappears
    /// silently.
    @concurrent public func install(replacing: Bool = false) async throws -> InstallOutcome {
        let source = try bundledCLI()
        let replaced = previousEntry()
        if let replaced, !replacing {
            throw Failure.occupied(path: destination.path, existing: replaced)
        }
        do {
            try installDirectly(source)
            return InstallOutcome(usedAdministratorPrivileges: false, destination: destination, source: source, replaced: replaced)
        } catch {
            guard Self.isPermissionDenied(error) else { throw error }
            try ensureDestinationIsNotDirectory()
            let parent = destination.deletingLastPathComponent().path
            try await privileged("/bin/mkdir -p \(Self.quoted(parent)) && /bin/rm -f \(Self.quoted(destination.path)) && "
                + "/bin/ln -s \(Self.quoted(source.path)) \(Self.quoted(destination.path))")
            try verifyLink(to: source)
            return InstallOutcome(usedAdministratorPrivileges: true, destination: destination, source: source, replaced: replaced)
        }
    }

    /// Removes the destination, through the administrator prompt when a direct removal is refused.
    @concurrent public func uninstall() async throws -> UninstallOutcome {
        do {
            let removed = try uninstallDirectly()
            return UninstallOutcome(usedAdministratorPrivileges: false, destination: destination, removedExistingEntry: removed)
        } catch {
            guard Self.isPermissionDenied(error) else { throw error }
            try ensureDestinationIsNotDirectory()
            let existed = destinationExists()
            try await privileged("/bin/rm -f \(Self.quoted(destination.path))")
            if destinationExists() { throw Failure.uninstallVerificationFailed(path: destination.path) }
            return UninstallOutcome(usedAdministratorPrivileges: true, destination: destination, removedExistingEntry: existed)
        }
    }

    /// Whether the destination is a symlink to this app's CLI.
    public func isInstalled() -> Bool {
        linkTarget() == source
    }

    // MARK: Steps

    private func bundledCLI() throws -> URL {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw Failure.bundledCLIMissing(path: source.path)
        }
        return source
    }

    private func installDirectly(_ source: URL) throws {
        try ensureParentDirectory()
        try ensureDestinationIsNotDirectory()
        if destinationExists() { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: source)
        try verifyLink(to: source)
    }

    private func uninstallDirectly() throws -> Bool {
        try ensureDestinationIsNotDirectory()
        let existed = destinationExists()
        if existed { try FileManager.default.removeItem(at: destination) }
        if destinationExists() { throw Failure.uninstallVerificationFailed(path: destination.path) }
        return existed
    }

    /// The entry install would replace, or nil when there is none, it is
    /// already this app's link, or it is a folder (`destinationIsDirectory`).
    private func previousEntry() -> Replaced? {
        guard destinationExists(), !isInstalled() else { return nil }
        if let values = try? destination.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
           values.isDirectory == true, values.isSymbolicLink != true {
            return nil
        }
        if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: destination.path) {
            return .link(target: target)
        }
        return .file
    }

    /// Any entry at the destination, a dangling symlink included
    /// (`fileExists` follows links).
    private func destinationExists() -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: destination.path)) != nil
    }

    private func verifyLink(to source: URL) throws {
        guard linkTarget() == source.standardizedFileURL else {
            throw Failure.installVerificationFailed(path: destination.path)
        }
    }

    private func linkTarget() -> URL? {
        guard FileManager.default.fileExists(atPath: destination.path),
              let target = try? FileManager.default.destinationOfSymbolicLink(atPath: destination.path) else { return nil }
        return URL(fileURLWithPath: target, relativeTo: destination.deletingLastPathComponent()).standardizedFileURL
    }

    private func ensureParentDirectory() throws {
        let parent = destination.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw Failure.destinationParentNotDirectory(path: parent.path) }
            return
        }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    }

    private func ensureDestinationIsNotDirectory() throws {
        guard let values = try? destination.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return }
        if values.isDirectory == true, values.isSymbolicLink != true {
            throw Failure.destinationIsDirectory(path: destination.path)
        }
    }

    // MARK: Administrator

    static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// `do shell script … with administrator privileges`, the command passed
    /// as an argument so it needs no AppleScript quoting.
    ///
    /// osascript starts through ``AsyncProcess`` (never on the caller's thread)
    /// at the caller's priority, and runs to its end even when the caller is
    /// cancelled: the command must not stop half way through a link.
    @concurrent public static func runAsAdministrator(_ command: String) async throws {
        let request = ProcessRequest(URL(fileURLWithPath: "/usr/bin/osascript"),
                                     ["-e", "on run argv", "-e", "do shell script (item 1 of argv) with administrator privileges",
                                      "-e", "end run", command],
                                     errorOutput: .separate, onCancel: .finish)
        let outcome = try await AsyncProcess().run(request)
        guard outcome.succeeded else {
            let text = String(decoding: outcome.errorOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure.privilegedCommandFailed(message: text.isEmpty ? "osascript exited with status \(outcome.status)" : text)
        }
    }

    static func isPermissionDenied(_ error: any Error) -> Bool {
        let error = error as NSError
        if error.domain == NSPOSIXErrorDomain, let code = POSIXErrorCode(rawValue: Int32(error.code)),
           [.EACCES, .EPERM, .EROFS].contains(code) {
            return true
        }
        if error.domain == NSCocoaErrorDomain,
           [NSFileWriteNoPermissionError, NSFileReadNoPermissionError, NSFileWriteVolumeReadOnlyError].contains(error.code) {
            return true
        }
        return (error.userInfo[NSUnderlyingErrorKey] as? NSError).map(isPermissionDenied) ?? false
    }
}
