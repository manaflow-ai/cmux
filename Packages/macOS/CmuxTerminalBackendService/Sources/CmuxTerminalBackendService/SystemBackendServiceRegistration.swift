internal import Darwin
internal import Dispatch
internal import Foundation
internal import ServiceManagement

internal protocol BackendServiceLaunchControlling: Sendable {
    func status(label: String, propertyListURL: URL) throws -> BackendServiceStatus
    func loadedProgramURL(label: String) throws -> URL?
    func bootstrap(propertyListURL: URL) throws
    func bootout(label: String) throws
    func bootoutExact(label: String, expectedProgramURL: URL) throws
}

internal extension BackendServiceLaunchControlling {
    func bootoutExact(label: String, expectedProgramURL: URL) throws {
        let actual = try loadedProgramURL(label: label)
        guard actual?.standardizedFileURL
            == expectedProgramURL.standardizedFileURL
        else {
            throw BackendServicePairError.loadedDescriptorChanged(
                expected: expectedProgramURL,
                actual: actual
            )
        }
        try bootout(label: label)
    }
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

    func bootoutExact(label: String, expectedProgramURL: URL) throws {
        let actual = try loadedProgramURL(label: label)
        guard actual?.standardizedFileURL == expectedProgramURL.standardizedFileURL else {
            throw BackendServicePairError.loadedDescriptorChanged(
                expected: expectedProgramURL,
                actual: actual
            )
        }
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
public actor SystemBackendServiceRegistration: BackendServiceRegistration,
    BackendServiceHandoffRegistering
{
    private let descriptor: BackendServiceDescriptor
    private let installer: BackendServicePairInstaller
    private let launchController: any BackendServiceLaunchControlling
    private let propertyListURL: URL
    private let serviceControlLock: any BackendServiceHandoffLocking

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
            launchController: SystemBackendServiceLaunchController(userID: userID),
            serviceControlLock: SystemBackendServiceHandoffLock(
                runtimePaths: runtimePaths,
                expectedUserID: userID
            )
        )
    }

    internal init(
        descriptor: BackendServiceDescriptor,
        installer: BackendServicePairInstaller,
        propertyListURL: URL,
        launchController: any BackendServiceLaunchControlling,
        serviceControlLock: (any BackendServiceHandoffLocking)? = nil
    ) {
        self.descriptor = descriptor
        self.installer = installer
        self.propertyListURL = propertyListURL
        self.launchController = launchController
        self.serviceControlLock = serviceControlLock ?? SystemBackendServiceHandoffLock(
            installationRootURL: installer.installationRootURL,
            expectedUserID: installer.expectedUserID
        )
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

    internal func activeHandoffDescriptor() throws -> BackendServiceHandoffLaunchDescriptor? {
        guard let pair = try activeInstalledPair() else { return nil }
        try validateLaunchAgentFile(propertyListURL)
        let data = try Data(contentsOf: propertyListURL)
        try validateLaunchAgentPayload(data, for: pair)
        return BackendServiceHandoffLaunchDescriptor(pair: pair, propertyListData: data)
    }

    internal func bootoutExact(
        _ descriptor: BackendServiceHandoffLaunchDescriptor
    ) throws {
        guard try activeHandoffDescriptor() == descriptor else {
            throw BackendServicePairError.loadedDescriptorChanged(
                expected: descriptor.pair.backendExecutableURL,
                actual: try launchController.loadedProgramURL(label: self.descriptor.serviceLabel)
            )
        }
        try launchController.bootoutExact(
            label: self.descriptor.serviceLabel,
            expectedProgramURL: descriptor.pair.backendExecutableURL
        )
    }

    internal func writeHandoffDescriptor(
        for pair: BackendServiceInstalledPair
    ) throws -> BackendServiceHandoffLaunchDescriptor {
        guard try activeInstalledPair() == nil else {
            throw BackendServicePairError.loadedDescriptorChanged(
                expected: pair.backendExecutableURL,
                actual: try launchController.loadedProgramURL(label: descriptor.serviceLabel)
            )
        }
        let validated = try installer.validateInstalledPair(
            at: pair.installationDirectoryURL,
            expectedBuildID: pair.buildID
        )
        let data = try launchAgentData(for: validated)
        try writeLaunchAgentData(data)
        return BackendServiceHandoffLaunchDescriptor(pair: validated, propertyListData: data)
    }

    internal func restoreHandoffDescriptor(
        _ descriptor: BackendServiceHandoffLaunchDescriptor
    ) throws {
        guard try activeInstalledPair() == nil else {
            throw BackendServicePairError.loadedDescriptorChanged(
                expected: descriptor.pair.backendExecutableURL,
                actual: try launchController.loadedProgramURL(label: self.descriptor.serviceLabel)
            )
        }
        let pair = try installer.validateInstalledPair(
            at: descriptor.pair.installationDirectoryURL,
            expectedBuildID: descriptor.pair.buildID
        )
        guard pair == descriptor.pair else {
            throw BackendServicePairError.launchAgentDescriptorChanged(propertyListURL)
        }
        try validateLaunchAgentPayload(descriptor.propertyListData, for: pair)
        try writeLaunchAgentData(descriptor.propertyListData)
    }

    internal func bootstrapExact(
        _ descriptor: BackendServiceHandoffLaunchDescriptor
    ) throws {
        try validateLaunchAgentFile(propertyListURL)
        let onDisk = try Data(contentsOf: propertyListURL)
        guard onDisk == descriptor.propertyListData else {
            throw BackendServicePairError.launchAgentDescriptorChanged(propertyListURL)
        }
        try validateLaunchAgentPayload(onDisk, for: descriptor.pair)
        guard try activeInstalledPair() == nil else {
            throw BackendServicePairError.loadedDescriptorChanged(
                expected: descriptor.pair.backendExecutableURL,
                actual: try launchController.loadedProgramURL(label: self.descriptor.serviceLabel)
            )
        }
        do {
            try launchController.bootstrap(propertyListURL: propertyListURL)
        } catch {
            guard try activeHandoffDescriptor() == descriptor else { throw error }
            return
        }
        guard try activeHandoffDescriptor() == descriptor else {
            throw BackendServicePairError.loadedDescriptorChanged(
                expected: descriptor.pair.backendExecutableURL,
                actual: try launchController.loadedProgramURL(label: self.descriptor.serviceLabel)
            )
        }
    }

    /// Loads the exact absolute daemon path without replacing a live descriptor.
    public func register(_ pair: BackendServiceInstalledPair) throws {
        let validated = try installer.validateInstalledPair(
            at: pair.installationDirectoryURL,
            expectedBuildID: pair.buildID
        )
        if try activeInstalledPair() != nil {
            return
        }
        try writeLaunchAgent(for: validated)
        do {
            try launchController.bootstrap(propertyListURL: propertyListURL)
        } catch {
            // Registration is serialized only within this actor. Another app
            // process can win launchd's cross-process bootstrap race after our
            // initial lookup. Trust that winner only after validating the exact
            // loaded immutable pair; otherwise preserve the original failure.
            if try activeInstalledPair() != nil { return }
            throw error
        }
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
        return active.buildID == pair.buildID
            ? .activated(active)
            : .deferred(active: active)
    }

    /// Explicit teardown is the only operation allowed to stop a loaded daemon.
    public func unregister() async throws {
        let loadedSnapshot = try activeHandoffDescriptor()
        let propertyListSnapshot: Data?
        if let loadedSnapshot {
            propertyListSnapshot = loadedSnapshot.propertyListData
        } else {
            propertyListSnapshot = try snapshotLaunchAgentDataIfPresent()
        }
        let lease = try await serviceControlLock.acquire()
        do {
            try unregisterUnderServiceControlLock(
                loadedSnapshot: loadedSnapshot,
                propertyListSnapshot: propertyListSnapshot
            )
        } catch {
            await lease.release()
            throw error
        }
        await lease.release()
    }

    private func unregisterUnderServiceControlLock(
        loadedSnapshot: BackendServiceHandoffLaunchDescriptor?,
        propertyListSnapshot: Data?
    ) throws {
        let active = try activeHandoffDescriptor()
        guard active == loadedSnapshot else {
            if let loadedSnapshot {
                throw BackendServicePairError.loadedDescriptorChanged(
                    expected: loadedSnapshot.pair.backendExecutableURL,
                    actual: active?.pair.backendExecutableURL
                )
            }
            throw BackendServicePairError.launchAgentDescriptorChanged(propertyListURL)
        }
        if let loadedSnapshot {
            try bootoutExact(loadedSnapshot)
        }
        let replacement = try launchController.loadedProgramURL(
            label: descriptor.serviceLabel
        )
        guard replacement == nil else {
            throw BackendServicePairError.loadedDescriptorChanged(
                expected: loadedSnapshot?.pair.backendExecutableURL ?? propertyListURL,
                actual: replacement
            )
        }
        try removeLaunchAgentIfExact(propertyListSnapshot)
    }

    private func snapshotLaunchAgentDataIfPresent() throws -> Data? {
        guard FileManager.default.fileExists(atPath: propertyListURL.path) else {
            return nil
        }
        try validateLaunchAgentFile(propertyListURL)
        return try Data(contentsOf: propertyListURL)
    }

    private func removeLaunchAgentIfExact(_ expectedData: Data?) throws {
        guard let expectedData else {
            guard !FileManager.default.fileExists(atPath: propertyListURL.path) else {
                throw BackendServicePairError.launchAgentDescriptorChanged(propertyListURL)
            }
            return
        }
        guard FileManager.default.fileExists(atPath: propertyListURL.path) else {
            return
        }
        try validateLaunchAgentFile(propertyListURL)
        guard try Data(contentsOf: propertyListURL) == expectedData else {
            throw BackendServicePairError.launchAgentDescriptorChanged(propertyListURL)
        }
        try FileManager.default.removeItem(at: propertyListURL)
        try synchronize(propertyListURL.deletingLastPathComponent(), isDirectory: true)
    }

    public func openSystemSettingsLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func writeLaunchAgent(for pair: BackendServiceInstalledPair) throws {
        try writeLaunchAgentData(launchAgentData(for: pair))
    }

    private func launchAgentData(for pair: BackendServiceInstalledPair) throws -> Data {
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
        return try PropertyListSerialization.data(
            fromPropertyList: payload,
            format: .xml,
            options: 0
        )
    }

    private func writeLaunchAgentData(_ data: Data) throws {
        let directory = propertyListURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        try validateLaunchAgentDirectory(directory)
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

    private func validateLaunchAgentPayload(
        _ data: Data,
        for pair: BackendServiceInstalledPair
    ) throws {
        guard let payload = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any],
              payload["Label"] as? String == descriptor.serviceLabel,
              payload["Program"] as? String == pair.backendExecutableURL.path,
              payload["ProgramArguments"] as? [String] == [
                  pair.backendExecutableURL.path,
                  "--headless",
                  "--app-service-layout",
                  "--session",
                  descriptor.sessionName,
              ],
              payload["WorkingDirectory"] as? String == pair.installationDirectoryURL.path,
              payload["KeepAlive"] as? Bool == true
        else {
            throw BackendServicePairError.launchAgentDescriptorChanged(propertyListURL)
        }
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
