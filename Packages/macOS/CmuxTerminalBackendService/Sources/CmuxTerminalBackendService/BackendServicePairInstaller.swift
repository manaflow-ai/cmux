internal import CryptoKit
internal import Darwin
internal import Dispatch
public import Foundation
internal import Security

internal protocol BackendServiceBuildIDReading: Sendable {
    func buildID(reportedBy executableURL: URL) throws -> String
}

internal protocol BackendServiceCodeSignatureValidating: Sendable {
    func validateCodeSignature(at executableURL: URL, expectedIdentifier: String) throws
}

internal protocol BackendServiceLiveExecutableCensusing: Sendable {
    func liveBackendExecutableURLs() throws -> [URL]
}

internal struct SystemBackendServiceBuildIDReader: BackendServiceBuildIDReading {
    func buildID(reportedBy executableURL: URL) throws -> String {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = executableURL
        process.arguments = ["--build-id"]
        process.standardOutput = output
        process.standardError = errors
        let completion = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completion.signal() }
        try process.run()
        guard completion.wait(timeout: .now() + .seconds(2)) == .success else {
            kill(process.processIdentifier, SIGKILL)
            _ = completion.wait(timeout: .now() + .seconds(1))
            throw BackendServicePairError.buildIDProbeTimedOut(executableURL)
        }
        let value = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            let message = String(
                decoding: errors.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            )
            throw BackendServicePairError.launchControlFailed(
                arguments: [executableURL.path, "--build-id"],
                status: process.terminationStatus,
                message: message
            )
        }
        return value
    }
}

internal struct SystemBackendServiceCodeSignatureValidator: BackendServiceCodeSignatureValidating {
    func validateCodeSignature(at executableURL: URL, expectedIdentifier: String) throws {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(
            executableURL as CFURL,
            [],
            &staticCode
        )
        guard createStatus == errSecSuccess, let staticCode else {
            throw BackendServicePairError.invalidCodeSignature(executableURL)
        }
        let validityStatus = SecStaticCodeCheckValidity(
            staticCode,
            SecCSFlags(rawValue: kSecCSStrictValidate),
            nil
        )
        guard validityStatus == errSecSuccess else {
            throw BackendServicePairError.invalidCodeSignature(executableURL)
        }
        var information: CFDictionary?
        let informationStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        )
        guard informationStatus == errSecSuccess, let information else {
            throw BackendServicePairError.invalidCodeSignature(executableURL)
        }
        let values = information as NSDictionary
        guard values[kSecCodeInfoIdentifier] as? String == expectedIdentifier else {
            throw BackendServicePairError.invalidCodeSignature(executableURL)
        }
    }
}

internal struct SystemBackendServiceLiveExecutableCensus: BackendServiceLiveExecutableCensusing {
    func liveBackendExecutableURLs() throws -> [URL] {
        var result: [URL] = []
        for processID in try allProcessIDs() where processID > 0 {
            // PROC_PIDPATHINFO_MAXSIZE is a C expression macro and therefore
            // is not imported into Swift. Keep the Darwin definition here.
            var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
            let length = path.withUnsafeMutableBytes { bytes in
                proc_pidpath(processID, bytes.baseAddress, UInt32(bytes.count))
            }
            guard length > 0 else { continue }
            let value = String(
                decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
                as: UTF8.self
            )
            let url = URL(fileURLWithPath: value, isDirectory: false)
            if url.lastPathComponent == "cmux-terminal-backend" {
                result.append(url)
            }
        }
        return result
    }

    private func allProcessIDs() throws -> [pid_t] {
        var capacity = max(Int(proc_listallpids(nil, 0)) * 2, 256)
        for _ in 0 ..< 4 {
            var processIDs = [pid_t](repeating: 0, count: capacity)
            let byteCount = processIDs.count * MemoryLayout<pid_t>.stride
            let count = processIDs.withUnsafeMutableBytes { bytes in
                proc_listallpids(bytes.baseAddress, Int32(byteCount))
            }
            guard count >= 0 else { throw CocoaError(.fileReadUnknown) }
            if Int(count) < capacity {
                return Array(processIDs.prefix(Int(count)))
            }
            capacity *= 2
        }
        throw CocoaError(.fileReadUnknown)
    }
}

/// Installs and revalidates immutable, build-ID-matched daemon and renderer pairs.
public struct BackendServicePairInstaller: Sendable {
    private static let backendName = "cmux-terminal-backend"
    private static let manifestName = "pair-manifest.json"

    public let descriptor: BackendServiceDescriptor
    public let bundleInspection: BackendServiceBundleInspection
    public let installationRootURL: URL
    public let expectedUserID: UInt32

    private let buildIDReader: any BackendServiceBuildIDReading
    private let codeSignatureValidator: any BackendServiceCodeSignatureValidating
    private let liveExecutableCensus: any BackendServiceLiveExecutableCensusing

    /// Creates the production immutable-pair installer.
    public init(
        descriptor: BackendServiceDescriptor,
        bundleInspection: BackendServiceBundleInspection,
        installationRootURL: URL,
        expectedUserID: UInt32
    ) {
        self.init(
            descriptor: descriptor,
            bundleInspection: bundleInspection,
            installationRootURL: installationRootURL,
            expectedUserID: expectedUserID,
            buildIDReader: SystemBackendServiceBuildIDReader(),
            codeSignatureValidator: SystemBackendServiceCodeSignatureValidator(),
            liveExecutableCensus: SystemBackendServiceLiveExecutableCensus()
        )
    }

    internal init(
        descriptor: BackendServiceDescriptor,
        bundleInspection: BackendServiceBundleInspection,
        installationRootURL: URL,
        expectedUserID: UInt32,
        buildIDReader: any BackendServiceBuildIDReading,
        codeSignatureValidator: any BackendServiceCodeSignatureValidating,
        liveExecutableCensus: any BackendServiceLiveExecutableCensusing
    ) {
        self.descriptor = descriptor
        self.bundleInspection = bundleInspection
        self.installationRootURL = installationRootURL
        self.expectedUserID = expectedUserID
        self.buildIDReader = buildIDReader
        self.codeSignatureValidator = codeSignatureValidator
        self.liveExecutableCensus = liveExecutableCensus
    }

    /// Validates the bundled pair and atomically stages its immutable version.
    public func installBundledPair() throws -> BackendServiceInstalledPair {
        if let missing = bundleInspection.firstMissingItem() {
            throw BackendServicePairError.missingArtifact(missing.url)
        }
        let backendBuildID = try readBuildID(bundleInspection.backendBuildIDURL)
        let rendererBuildID = try readBuildID(bundleInspection.rendererBuildIDURL)
        guard rendererBuildID == backendBuildID else {
            throw BackendServicePairError.buildIDMismatch(
                expected: backendBuildID,
                actual: rendererBuildID,
                bundleInspection.rendererBuildIDURL
            )
        }
        try codeSignatureValidator.validateCodeSignature(
            at: bundleInspection.executableURL,
            expectedIdentifier: "com.cmuxterm.cmux-terminal-backend"
        )
        try codeSignatureValidator.validateCodeSignature(
            at: bundleInspection.rendererExecutableURL,
            expectedIdentifier: "com.cmuxterm.cmux-terminal-renderer"
        )
        let reportedBuildID = try buildIDReader.buildID(reportedBy: bundleInspection.executableURL)
        guard reportedBuildID == backendBuildID else {
            throw BackendServicePairError.executableBuildIDMismatch(
                expected: backendBuildID,
                actual: reportedBuildID
            )
        }

        let versionsURL = installationRootURL.appendingPathComponent("versions", isDirectory: true)
        try createPrivateDirectory(installationRootURL)
        try createPrivateDirectory(versionsURL)
        let installLock = try acquireInstallLock()
        defer {
            flock(installLock, LOCK_UN)
            close(installLock)
        }
        try reapStaleInstallDirectories(in: versionsURL)
        let destination = versionsURL.appendingPathComponent(backendBuildID, isDirectory: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            return try validateInstalledPair(at: destination, expectedBuildID: backendBuildID)
        }

        let staging = versionsURL.appendingPathComponent(
            ".install-\(backendBuildID)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: staging,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        var shouldRemoveStaging = true
        defer {
            if shouldRemoveStaging {
                try? FileManager.default.removeItem(at: staging)
            }
        }

        let backendDestination = staging.appendingPathComponent(Self.backendName)
        let rendererDestination = staging.appendingPathComponent(descriptor.rendererExecutableName)
        let backendBuildIDDestination = URL(fileURLWithPath: backendDestination.path + ".build-id")
        let rendererBuildIDDestination = URL(fileURLWithPath: rendererDestination.path + ".build-id")
        try copy(bundleInspection.executableURL, to: backendDestination, permissions: 0o500)
        try copy(bundleInspection.rendererExecutableURL, to: rendererDestination, permissions: 0o500)
        try copy(bundleInspection.backendBuildIDURL, to: backendBuildIDDestination, permissions: 0o400)
        try copy(bundleInspection.rendererBuildIDURL, to: rendererBuildIDDestination, permissions: 0o400)

        let manifest = BackendServicePairManifest(
            schemaVersion: BackendServiceInstalledPair.manifestSchemaVersion,
            bundleIdentifier: descriptor.bundleIdentifier,
            serviceLabel: descriptor.serviceLabel,
            buildID: backendBuildID,
            backend: try manifestArtifact(backendDestination),
            renderer: try manifestArtifact(rendererDestination)
        )
        let manifestURL = staging.appendingPathComponent(Self.manifestName)
        let manifestData = try JSONEncoder.stable.encode(manifest)
        try manifestData.write(to: manifestURL, options: .withoutOverwriting)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o400],
            ofItemAtPath: manifestURL.path
        )
        for file in [
            backendDestination,
            rendererDestination,
            backendBuildIDDestination,
            rendererBuildIDDestination,
            manifestURL,
        ] {
            try synchronize(file, isDirectory: false)
        }
        try synchronize(staging, isDirectory: true)

        do {
            try FileManager.default.moveItem(at: staging, to: destination)
            shouldRemoveStaging = false
            try synchronize(versionsURL, isDirectory: true)
        } catch where FileManager.default.fileExists(atPath: destination.path) {
            // Another app instance installed the same content-derived version.
        }
        return try validateInstalledPair(at: destination, expectedBuildID: backendBuildID)
    }

    /// Revalidates every artifact and returns an exact trusted descriptor.
    public func validateInstalledPair(
        at directoryURL: URL,
        expectedBuildID: String? = nil
    ) throws -> BackendServiceInstalledPair {
        try validatePrivateDirectory(installationRootURL)
        try validatePrivateDirectory(
            installationRootURL.appendingPathComponent("versions", isDirectory: true)
        )
        try validatePrivateDirectory(directoryURL)
        let manifestURL = directoryURL.appendingPathComponent(Self.manifestName)
        try validatePrivateFile(manifestURL, expectedMode: 0o400)
        let manifest: BackendServicePairManifest
        do {
            manifest = try JSONDecoder().decode(
                BackendServicePairManifest.self,
                from: Data(contentsOf: manifestURL)
            )
        } catch {
            throw BackendServicePairError.invalidManifest(manifestURL)
        }
        guard manifest.schemaVersion == BackendServiceInstalledPair.manifestSchemaVersion,
              isBuildID(manifest.buildID),
              directoryURL.lastPathComponent == manifest.buildID,
              expectedBuildID == nil || expectedBuildID == manifest.buildID
        else {
            throw BackendServicePairError.invalidManifest(manifestURL)
        }
        guard manifest.bundleIdentifier == descriptor.bundleIdentifier else {
            throw BackendServicePairError.manifestIdentityMismatch(
                expected: descriptor.bundleIdentifier,
                actual: manifest.bundleIdentifier
            )
        }
        guard manifest.serviceLabel == descriptor.serviceLabel else {
            throw BackendServicePairError.manifestIdentityMismatch(
                expected: descriptor.serviceLabel,
                actual: manifest.serviceLabel
            )
        }
        guard manifest.backend.fileName == Self.backendName,
              manifest.renderer.fileName == descriptor.rendererExecutableName
        else {
            throw BackendServicePairError.invalidManifest(manifestURL)
        }

        let backendURL = directoryURL.appendingPathComponent(Self.backendName)
        let rendererURL = directoryURL.appendingPathComponent(descriptor.rendererExecutableName)
        try validatePrivateFile(backendURL, expectedMode: 0o500)
        try validatePrivateFile(rendererURL, expectedMode: 0o500)
        try validateManifestArtifact(manifest.backend, at: backendURL)
        try validateManifestArtifact(manifest.renderer, at: rendererURL)

        let backendBuildIDURL = URL(fileURLWithPath: backendURL.path + ".build-id")
        let rendererBuildIDURL = URL(fileURLWithPath: rendererURL.path + ".build-id")
        try validatePrivateFile(backendBuildIDURL, expectedMode: 0o400)
        try validatePrivateFile(rendererBuildIDURL, expectedMode: 0o400)
        for sidecar in [backendBuildIDURL, rendererBuildIDURL] {
            let sidecarBuildID = try readBuildID(sidecar)
            guard sidecarBuildID == manifest.buildID else {
                throw BackendServicePairError.buildIDMismatch(
                    expected: manifest.buildID,
                    actual: sidecarBuildID,
                    sidecar
                )
            }
        }
        try codeSignatureValidator.validateCodeSignature(
            at: backendURL,
            expectedIdentifier: "com.cmuxterm.cmux-terminal-backend"
        )
        try codeSignatureValidator.validateCodeSignature(
            at: rendererURL,
            expectedIdentifier: "com.cmuxterm.cmux-terminal-renderer"
        )
        let reportedBuildID = try buildIDReader.buildID(reportedBy: backendURL)
        guard reportedBuildID == manifest.buildID else {
            throw BackendServicePairError.executableBuildIDMismatch(
                expected: manifest.buildID,
                actual: reportedBuildID
            )
        }

        return BackendServiceInstalledPair(
            buildID: manifest.buildID,
            installationDirectoryURL: directoryURL,
            backendExecutableURL: backendURL,
            rendererExecutableURL: rendererURL,
            manifestURL: manifestURL
        )
    }

    /// Validates an absolute loaded daemon path without trusting mutable app state.
    public func validateInstalledBackend(at executableURL: URL) throws -> BackendServiceInstalledPair {
        guard executableURL.lastPathComponent == Self.backendName else {
            throw BackendServicePairError.executableOutsideInstallation(executableURL)
        }
        let directory = executableURL.deletingLastPathComponent()
        let versions = installationRootURL.appendingPathComponent("versions", isDirectory: true)
        guard directory.deletingLastPathComponent().standardizedFileURL == versions.standardizedFileURL else {
            throw BackendServicePairError.executableOutsideInstallation(executableURL)
        }
        let pair = try validateInstalledPair(at: directory)
        guard pair.backendExecutableURL.standardizedFileURL == executableURL.standardizedFileURL else {
            throw BackendServicePairError.executableOutsideInstallation(executableURL)
        }
        return pair
    }

    /// Removes only versions that are not referenced by a live backend process.
    @discardableResult
    public func garbageCollect(
        preserving explicitlyPreserved: Set<String> = []
    ) throws -> [String] {
        let liveExecutables = try liveExecutableCensus.liveBackendExecutableURLs()
        var preserved = explicitlyPreserved
        for executable in liveExecutables {
            guard executable.lastPathComponent == Self.backendName else { continue }
            let directory = executable.deletingLastPathComponent()
            let versions = installationRootURL.appendingPathComponent("versions", isDirectory: true)
            if directory.deletingLastPathComponent().standardizedFileURL == versions.standardizedFileURL,
               isBuildID(directory.lastPathComponent)
            {
                preserved.insert(directory.lastPathComponent)
            }
        }

        let versions = installationRootURL.appendingPathComponent("versions", isDirectory: true)
        guard FileManager.default.fileExists(atPath: versions.path) else { return [] }
        try validatePrivateDirectory(installationRootURL)
        try validatePrivateDirectory(versions)
        var removed: [String] = []
        for child in try FileManager.default.contentsOfDirectory(
            at: versions,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) {
            let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let buildID = child.lastPathComponent
            guard values.isDirectory == true,
                  values.isSymbolicLink != true,
                  isBuildID(buildID),
                  !preserved.contains(buildID)
            else { continue }
            try FileManager.default.removeItem(at: child)
            removed.append(buildID)
        }
        return removed.sorted()
    }

    private func createPrivateDirectory(_ url: URL) throws {
        var existingStatus = stat()
        if lstat(url.path, &existingStatus) == 0 {
            try validatePrivateDirectory(url)
            return
        }
        guard errno == ENOENT else { throw CocoaError(.fileWriteUnknown) }

        var missing: [URL] = [url]
        var parent = url.deletingLastPathComponent()
        while true {
            var parentStatus = stat()
            if lstat(parent.path, &parentStatus) == 0 {
                if parentStatus.st_mode & S_IFMT == S_IFLNK {
                    throw BackendServicePairError.symbolicLink(parent)
                }
                guard parentStatus.st_mode & S_IFMT == S_IFDIR else {
                    throw BackendServicePairError.notDirectory(parent)
                }
                break
            }
            guard errno == ENOENT else { throw CocoaError(.fileWriteUnknown) }
            let nextParent = parent.deletingLastPathComponent()
            guard nextParent.path != parent.path else {
                throw BackendServicePairError.notDirectory(parent)
            }
            missing.append(parent)
            parent = nextParent
        }

        for directory in missing.reversed() {
            if mkdir(directory.path, 0o700) != 0 {
                guard errno == EEXIST else { throw CocoaError(.fileWriteUnknown) }
            }
            try validatePrivateDirectory(directory)
        }
    }

    private func acquireInstallLock() throws -> Int32 {
        let lockURL = installationRootURL.appendingPathComponent(".install.lock")
        let descriptor = open(
            lockURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            0o600
        )
        guard descriptor >= 0 else {
            if errno == ELOOP { throw BackendServicePairError.symbolicLink(lockURL) }
            throw CocoaError(.fileWriteUnknown)
        }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            close(descriptor)
            throw CocoaError(.fileReadUnknown)
        }
        let mode = UInt16(status.st_mode & 0o7777)
        guard status.st_mode & S_IFMT == S_IFREG else {
            close(descriptor)
            throw BackendServicePairError.notRegularFile(lockURL)
        }
        guard status.st_uid == expectedUserID else {
            close(descriptor)
            throw BackendServicePairError.wrongOwner(
                lockURL,
                expected: expectedUserID,
                actual: status.st_uid
            )
        }
        guard mode == 0o600 else {
            close(descriptor)
            throw BackendServicePairError.unsafePermissions(lockURL, mode: mode)
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw BackendServicePairError.installLockBusy(lockURL)
        }
        return descriptor
    }

    private func reapStaleInstallDirectories(in versionsURL: URL) throws {
        var removedAny = false
        for child in try FileManager.default.contentsOfDirectory(
            at: versionsURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) where child.lastPathComponent.hasPrefix(".install-") {
            let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            do {
                try validatePrivateDirectory(child)
            } catch {
                continue
            }
            try FileManager.default.removeItem(at: child)
            removedAny = true
        }
        if removedAny {
            try synchronize(versionsURL, isDirectory: true)
        }
    }

    private func copy(_ source: URL, to destination: URL, permissions: Int) throws {
        try FileManager.default.copyItem(at: source, to: destination)
        try FileManager.default.setAttributes(
            [.posixPermissions: permissions],
            ofItemAtPath: destination.path
        )
    }

    private func manifestArtifact(_ url: URL) throws -> BackendServicePairManifest.Artifact {
        BackendServicePairManifest.Artifact(
            fileName: url.lastPathComponent,
            sha256: try sha256(url),
            size: try fileSize(url)
        )
    }

    private func validateManifestArtifact(
        _ artifact: BackendServicePairManifest.Artifact,
        at url: URL
    ) throws {
        let actualSize = try fileSize(url)
        guard actualSize == artifact.size else {
            throw BackendServicePairError.manifestSizeMismatch(
                url,
                expected: artifact.size,
                actual: actualSize
            )
        }
        let actualHash = try sha256(url)
        guard actualHash == artifact.sha256 else {
            throw BackendServicePairError.manifestHashMismatch(
                url,
                expected: artifact.sha256,
                actual: actualHash
            )
        }
    }

    private func sha256(_ url: URL) throws -> String {
        let digest = SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func fileSize(_ url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let number = attributes[.size] as? NSNumber else {
            throw BackendServicePairError.notRegularFile(url)
        }
        return number.uint64Value
    }

    private func readBuildID(_ url: URL) throws -> String {
        let value = try String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard isBuildID(value) else {
            throw BackendServicePairError.invalidBuildID(url, value: value)
        }
        return value
    }

    private func isBuildID(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            ($0 >= Character("0").asciiValue! && $0 <= Character("9").asciiValue!)
                || ($0 >= Character("a").asciiValue! && $0 <= Character("f").asciiValue!)
        }
    }

    private func validatePrivateDirectory(_ url: URL) throws {
        let status = try fileStatus(url)
        guard status.st_mode & S_IFMT == S_IFDIR else {
            throw BackendServicePairError.notDirectory(url)
        }
        try validateOwnerAndMode(url, status: status, expectedMode: 0o700)
    }

    private func validatePrivateFile(_ url: URL, expectedMode: UInt16) throws {
        let status = try fileStatus(url)
        guard status.st_mode & S_IFMT == S_IFREG else {
            throw BackendServicePairError.notRegularFile(url)
        }
        try validateOwnerAndMode(url, status: status, expectedMode: expectedMode)
        if expectedMode & 0o100 != 0, status.st_mode & S_IXUSR == 0 {
            throw BackendServicePairError.notExecutable(url)
        }
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

    private func validateOwnerAndMode(
        _ url: URL,
        status: stat,
        expectedMode: UInt16
    ) throws {
        guard status.st_uid == expectedUserID else {
            throw BackendServicePairError.wrongOwner(
                url,
                expected: expectedUserID,
                actual: status.st_uid
            )
        }
        let mode = UInt16(status.st_mode & 0o7777)
        guard mode == expectedMode else {
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

private extension BackendServiceMissingBundleItem {
    var url: URL {
        switch self {
        case let .propertyList(url),
             let .executable(url),
             let .rendererExecutable(url),
             let .backendBuildID(url),
             let .rendererBuildID(url),
             let .invalidArtifact(url):
            url
        }
    }
}

private extension JSONEncoder {
    static var stable: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
