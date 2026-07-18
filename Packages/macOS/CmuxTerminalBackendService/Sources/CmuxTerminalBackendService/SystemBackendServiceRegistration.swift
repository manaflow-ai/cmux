internal import Darwin
internal import Dispatch
internal import Foundation
internal import ServiceManagement

internal protocol BackendServiceLaunchControlling: Sendable {
    func status(label: String, propertyListURL: URL) throws -> BackendServiceStatus
    func loadedProgramURL(label: String) throws -> URL?
    func bootstrap(propertyListURL: URL) throws
    func bootout(label: String) throws
}

internal struct BackendServiceCommandResult: Equatable, Sendable {
    let arguments: [String]
    let status: Int32
    let output: String
}

internal protocol BackendServiceCommandRunning: Sendable {
    func run(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval
    ) throws -> BackendServiceCommandResult
}

internal struct BoundedBackendServiceCommandRunner: BackendServiceCommandRunning {
    func run(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval
    ) throws -> BackendServiceCommandResult {
        precondition(timeout > 0)
        let command = [executableURL.path] + arguments
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-backend-command-\(UUID().uuidString).log",
            isDirectory: false
        )
        let outputDescriptor = try createExclusivePrivateFile(
            at: outputURL,
            accessMode: O_RDWR
        )
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let outputHandle = FileHandle(
            fileDescriptor: outputDescriptor,
            closeOnDealloc: true
        )
        defer { try? outputHandle.close() }

        let process = Process()
        let completion = DispatchSemaphore(value: 0)
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = outputHandle
        process.standardError = outputHandle
        process.terminationHandler = { _ in completion.signal() }
        try process.run()

        let timeoutNanoseconds = Int(timeout * 1_000_000_000)
        if completion.wait(timeout: .now() + .nanoseconds(timeoutNanoseconds)) == .timedOut {
            kill(process.processIdentifier, SIGKILL)
            _ = completion.wait(timeout: .now() + 1)
            throw BackendServicePairError.launchControlTimedOut(arguments: command)
        }
        try outputHandle.synchronize()
        let output = String(
            decoding: try Data(contentsOf: outputURL),
            as: UTF8.self
        )
        return BackendServiceCommandResult(
            arguments: command,
            status: process.terminationStatus,
            output: output
        )
    }
}

internal struct SystemBackendServiceLaunchController: BackendServiceLaunchControlling {
    let userID: UInt32
    private let commandRunner: any BackendServiceCommandRunning

    init(
        userID: UInt32,
        commandRunner: any BackendServiceCommandRunning = BoundedBackendServiceCommandRunner()
    ) {
        self.userID = userID
        self.commandRunner = commandRunner
    }

    func status(label: String, propertyListURL _: URL) throws -> BackendServiceStatus {
        let result = try run(["print", domainTarget(label)])
        return result.status == 0 ? .enabled : .notRegistered
    }

    func loadedProgramURL(label: String) throws -> URL? {
        let result = try run(["print", domainTarget(label)])
        guard result.status == 0 else { return nil }
        for line in result.output.split(separator: "\n") {
            let components = line.split(separator: "=", maxSplits: 1)
            guard components.count == 2,
                  String(components[0]).trimmingCharacters(in: .whitespaces) == "program"
            else { continue }
            let value = String(components[1]).trimmingCharacters(in: .whitespaces)
            guard value.hasPrefix("/") else {
                throw BackendServicePairError.loadedDescriptorMissingProgram(label)
            }
            return URL(fileURLWithPath: value, isDirectory: false)
        }
        throw BackendServicePairError.loadedDescriptorMissingProgram(label)
    }

    func bootstrap(propertyListURL: URL) throws {
        let result = try run(["bootstrap", "gui/\(userID)", propertyListURL.path])
        guard result.status == 0 else {
            throw BackendServicePairError.launchControlFailed(
                arguments: result.arguments,
                status: result.status,
                message: result.output
            )
        }
    }

    func bootout(label: String) throws {
        guard try loadedProgramURL(label: label) != nil else { return }
        let result = try run(["bootout", domainTarget(label)])
        guard result.status == 0 else {
            throw BackendServicePairError.launchControlFailed(
                arguments: result.arguments,
                status: result.status,
                message: result.output
            )
        }
    }

    private func domainTarget(_ label: String) -> String {
        "gui/\(userID)/\(label)"
    }

    private func run(_ arguments: [String]) throws -> BackendServiceCommandResult {
        try commandRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/launchctl"),
            arguments: arguments,
            timeout: 5
        )
    }
}

/// Installs an immutable pair and owns its per-user launchd descriptor.
public actor SystemBackendServiceRegistration: BackendServiceRegistration {
    private let descriptor: BackendServiceDescriptor
    private let installer: BackendServicePairInstaller
    private let launchController: any BackendServiceLaunchControlling
    private let propertyListURL: URL

    /// Creates the production per-user service adapter.
    public init(
        descriptor: BackendServiceDescriptor,
        bundleInspection: BackendServiceBundleInspection,
        runtimePaths: BackendServiceRuntimePaths,
        userID: UInt32
    ) {
        self.init(
            descriptor: descriptor,
            installer: BackendServicePairInstaller(
                descriptor: descriptor,
                bundleInspection: bundleInspection,
                installationRootURL: runtimePaths.serviceInstallationRootURL,
                expectedUserID: userID
            ),
            propertyListURL: runtimePaths.launchAgentPropertyListURL,
            launchController: SystemBackendServiceLaunchController(userID: userID)
        )
    }

    internal init(
        descriptor: BackendServiceDescriptor,
        installer: BackendServicePairInstaller,
        propertyListURL: URL,
        launchController: any BackendServiceLaunchControlling
    ) {
        self.descriptor = descriptor
        self.installer = installer
        self.propertyListURL = propertyListURL
        self.launchController = launchController
    }

    public func prepareBundledPair() throws -> BackendServiceInstalledPair {
        try installer.installBundledPair()
    }

    public func status() throws -> BackendServiceStatus {
        try launchController.status(
            label: descriptor.serviceLabel,
            propertyListURL: propertyListURL
        )
    }

    public func activeInstalledPair() throws -> BackendServiceInstalledPair? {
        guard let program = try launchController.loadedProgramURL(label: descriptor.serviceLabel) else {
            return nil
        }
        return try installer.validateInstalledBackend(at: program)
    }

    /// Loads the exact absolute daemon path without replacing a live descriptor.
    public func register(_ pair: BackendServiceInstalledPair) throws {
        let validated = try installer.validateInstalledPair(
            at: pair.installationDirectoryURL,
            expectedBuildID: pair.buildID
        )
        if let active = try activeInstalledPair() {
            guard active.buildID == validated.buildID else {
                throw BackendServicePairError.liveServiceReplacementForbidden(
                    active: active.backendExecutableURL,
                    proposed: validated.backendExecutableURL
                )
            }
            return
        }
        try writeLaunchAgent(for: validated)
        try launchController.bootstrap(propertyListURL: propertyListURL)
    }

    public func activateIfServiceStopped(
        _ pair: BackendServiceInstalledPair
    ) throws -> BackendServicePairActivationResult {
        if let active = try activeInstalledPair() {
            return .deferred(active: active)
        }
        try register(pair)
        guard let active = try activeInstalledPair() else {
            throw BackendServicePairError.loadedDescriptorMissingProgram(
                descriptor.serviceLabel
            )
        }
        return .activated(active)
    }

    /// Explicit teardown is the only operation allowed to stop a loaded daemon.
    public func unregister() throws {
        if FileManager.default.fileExists(atPath: propertyListURL.path) {
            try validateLaunchAgentFile(propertyListURL)
        }
        try launchController.bootout(label: descriptor.serviceLabel)
        if FileManager.default.fileExists(atPath: propertyListURL.path) {
            try FileManager.default.removeItem(at: propertyListURL)
        }
    }

    public func openSystemSettingsLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func writeLaunchAgent(for pair: BackendServiceInstalledPair) throws {
        let directory = propertyListURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        try validateLaunchAgentDirectory(directory)
        let payload: [String: Any] = [
            "Label": descriptor.serviceLabel,
            "Program": pair.backendExecutableURL.path,
            "ProgramArguments": [
                pair.backendExecutableURL.path,
                "--headless",
                "--app-service-layout",
                "--session",
                descriptor.sessionName,
            ],
            "WorkingDirectory": pair.installationDirectoryURL.path,
            "KeepAlive": true,
            "ProcessType": "Interactive",
            "ThrottleInterval": 5,
            "Umask": 63,
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: payload,
            format: .xml,
            options: 0
        )
        let temporary = directory.appendingPathComponent(
            ".\(descriptor.propertyListName).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        try writeExclusivePrivateFile(data, to: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try synchronize(temporary, isDirectory: false)
        if FileManager.default.fileExists(atPath: propertyListURL.path) {
            try validateLaunchAgentFile(propertyListURL)
        }
        guard rename(temporary.path, propertyListURL.path) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        try synchronize(directory, isDirectory: true)
        try validateLaunchAgentFile(propertyListURL)
    }

    private func validateLaunchAgentDirectory(_ url: URL) throws {
        let status = try fileStatus(url)
        guard status.st_mode & S_IFMT == S_IFDIR else {
            throw BackendServicePairError.notDirectory(url)
        }
        try validateLaunchAgentOwnershipAndMode(url, status: status)
    }

    private func validateLaunchAgentFile(_ url: URL) throws {
        let status = try fileStatus(url)
        guard status.st_mode & S_IFMT == S_IFREG else {
            throw BackendServicePairError.notRegularFile(url)
        }
        try validateLaunchAgentOwnershipAndMode(url, status: status)
    }

    private func fileStatus(_ url: URL) throws -> stat {
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            throw BackendServicePairError.missingArtifact(url)
        }
        if status.st_mode & S_IFMT == S_IFLNK {
            throw BackendServicePairError.symbolicLink(url)
        }
        return status
    }

    private func validateLaunchAgentOwnershipAndMode(_ url: URL, status: stat) throws {
        guard status.st_uid == installer.expectedUserID else {
            throw BackendServicePairError.wrongOwner(
                url,
                expected: installer.expectedUserID,
                actual: status.st_uid
            )
        }
        let mode = UInt16(status.st_mode & 0o7777)
        guard status.st_mode & (S_IWGRP | S_IWOTH) == 0 else {
            throw BackendServicePairError.unsafePermissions(url, mode: mode)
        }
        if status.st_mode & S_IFMT == S_IFREG, mode != 0o600 {
            throw BackendServicePairError.unsafePermissions(url, mode: mode)
        }
    }

    private func synchronize(_ url: URL, isDirectory: Bool) throws {
        let flags = isDirectory ? O_RDONLY | O_DIRECTORY : O_RDONLY
        let descriptor = open(url.path, flags)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}

private func createExclusivePrivateFile(
    at url: URL,
    accessMode: Int32
) throws -> Int32 {
    let descriptor = open(
        url.path,
        accessMode | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
        0o600
    )
    guard descriptor >= 0 else {
        if errno == ELOOP { throw BackendServicePairError.symbolicLink(url) }
        throw CocoaError(.fileWriteUnknown)
    }
    guard fchmod(descriptor, 0o600) == 0 else {
        close(descriptor)
        unlink(url.path)
        throw CocoaError(.fileWriteUnknown)
    }
    return descriptor
}

private func writeExclusivePrivateFile(_ data: Data, to url: URL) throws {
    let descriptor = try createExclusivePrivateFile(at: url, accessMode: O_WRONLY)
    var descriptorIsOpen = true
    defer {
        if descriptorIsOpen { close(descriptor) }
    }
    do {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw CocoaError(.fileWriteUnknown) }
                offset += written
            }
        }
        guard close(descriptor) == 0 else {
            descriptorIsOpen = false
            throw CocoaError(.fileWriteUnknown)
        }
        descriptorIsOpen = false
    } catch {
        try? FileManager.default.removeItem(at: url)
        throw error
    }
}
