import Foundation

/// Install cmux CLI in PATH: a symlink at /usr/local/bin/cmux to the bundled
/// CLI (Contents/Resources/bin/cmux), as the old app made it. When the user
/// cannot write /usr/local/bin, the same commands run once more through an
/// administrator prompt (osascript `with administrator privileges`).
nonisolated struct CLIPathInstaller: Sendable {
    nonisolated struct InstallOutcome: Equatable, Sendable {
        let usedAdministratorPrivileges: Bool
        let destination: URL
        let source: URL
        /// What was at the destination before, when it was not already this
        /// app's link. Install still replaces it (the old app's Install CLI
        /// did too) but says so, so another app's `cmux` never disappears
        /// silently.
        var replaced: Replaced? = nil
    }

    nonisolated enum Replaced: Equatable, Sendable {
        /// A symlink, with its target as written.
        case link(target: String)
        /// A file or other non-link entry.
        case file
    }

    nonisolated struct UninstallOutcome: Equatable, Sendable {
        let usedAdministratorPrivileges: Bool
        let destination: URL
        let removedExistingEntry: Bool
    }

    nonisolated enum Failure: Error, Equatable {
        case bundledCLIMissing(path: String)
        case destinationParentNotDirectory(path: String)
        case destinationIsDirectory(path: String)
        case installVerificationFailed(path: String)
        case uninstallVerificationFailed(path: String)
        case privilegedCommandFailed(message: String)
    }

    /// Runs a shell command as administrator; throws `privilegedCommandFailed`.
    typealias Privileged = @Sendable (_ command: String) async throws -> Void

    let destination: URL
    let source: URL
    let privileged: Privileged

    init(destination: URL = URL(fileURLWithPath: "/usr/local/bin/cmux"),
         source: URL = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/bin/cmux"),
         privileged: @escaping Privileged = CLIPathInstaller.runAsAdministrator) {
        self.destination = destination
        self.source = source.standardizedFileURL
        self.privileged = privileged
    }

    @concurrent func install() async throws -> InstallOutcome {
        let source = try bundledCLI()
        let replaced = previousEntry()
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

    @concurrent func uninstall() async throws -> UninstallOutcome {
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
    func isInstalled() -> Bool {
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

    /// The entry install would replace, or nil when there is none or it is
    /// already this app's link.
    private func previousEntry() -> Replaced? {
        guard destinationExists(), !isInstalled() else { return nil }
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
    @concurrent static func runAsAdministrator(_ command: String) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "on run argv", "-e", "do shell script (item 1 of argv) with administrator privileges",
                             "-e", "end run", command]
        let errors = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        let exited = AsyncStream.makeStream(of: Int32.self, bufferingPolicy: .bufferingNewest(1))
        process.terminationHandler = { process in
            exited.continuation.yield(process.terminationStatus)
            exited.continuation.finish()
        }
        try process.run()
        var message: [UInt8] = []
        for try await byte in errors.fileHandleForReading.bytes { message.append(byte) }
        var status: Int32 = -1
        for await code in exited.stream { status = code }
        guard status == 0 else {
            let text = String(decoding: message, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure.privilegedCommandFailed(message: text.isEmpty ? "osascript exited with status \(status)" : text)
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
