import Testing
import Darwin
import Foundation
@testable import CMUXSocketPathDomain

@Test func markerFilesAreVariantAware() {
    #expect(SocketPathMarkerFiles.variant(
        bundleIdentifier: "com.cmuxterm.app",
        environment: [:]
    ) == .stable)
    #expect(SocketPathMarkerFiles.variant(
        bundleIdentifier: "com.cmuxterm.app.nightly",
        environment: [:]
    ) == .nightly(slug: nil))
    #expect(SocketPathMarkerFiles.variant(
        bundleIdentifier: "com.cmuxterm.app.debug.agent",
        environment: [:]
    ) == .dev(slug: "agent"))
    #expect(SocketPathMarkerFiles.variant(
        bundleIdentifier: "com.cmuxterm.app.debug",
        environment: ["CMUX_TAG": "Issue 3542"]
    ) == .dev(slug: "issue-3542"))
    #expect(SocketPathMarkerFiles.variant(
        bundleIdentifier: "com.cmuxterm.app.debug",
        environment: ["CMUX_TAG": "café"]
    ) == .dev(slug: "caf"))
}

@Test func defaultSocketPathsStayVariantScoped() {
    #expect(SocketPathMarkerFiles.defaultSocketPath(
        bundleIdentifier: "com.cmuxterm.app",
        environment: [:],
        isDebugBuild: false,
        stableSocketPath: "/stable/cmux.sock"
    ) == "/stable/cmux.sock")
    #expect(SocketPathMarkerFiles.defaultSocketPath(
        bundleIdentifier: "com.cmuxterm.app.nightly",
        environment: [:],
        isDebugBuild: false,
        stableSocketPath: "/stable/cmux.sock"
    ) == "/tmp/cmux-nightly.sock")
    #expect(SocketPathMarkerFiles.defaultSocketPath(
        bundleIdentifier: "com.cmuxterm.app.staging.my-feature",
        environment: [:],
        isDebugBuild: false,
        stableSocketPath: "/stable/cmux.sock"
    ) == "/tmp/cmux-staging-my-feature.sock")
    #expect(SocketPathMarkerFiles.defaultSocketPath(
        bundleIdentifier: "com.cmuxterm.app.debug",
        environment: ["CMUX_TAG": "Issue 3542"],
        isDebugBuild: false,
        stableSocketPath: "/stable/cmux.sock"
    ) == "/tmp/cmux-debug-issue-3542.sock")
}

@Test func unlinkPathIfPresentTreatsMissingPathAsSuccess() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let path = root.appendingPathComponent("missing.sock").path
    #expect(SocketPathProbe.unlinkPathIfPresent(path) == 0)
}

@Test func unlinkPathIfPresentRemovesExistingFile() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let pathURL = root.appendingPathComponent("replacement")
    try Data("replacement".utf8).write(to: pathURL)

    #expect(SocketPathProbe.unlinkPathIfPresent(pathURL.path) == 0)
    #expect(!FileManager.default.fileExists(atPath: pathURL.path))
}

@Test func unlinkIfNoLiveOtherOwnerTreatsMissingPathAsSuccess() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let path = root.appendingPathComponent("missing.sock").path
    #expect(SocketPathProbe.unlinkIfNoLiveOtherOwner(path, expectedOwnerPID: getpid(), timeout: 0) == 0)
}

@Test func socketRecoveryOnlyAttemptsDefinitiveStalePathFailures() {
    #expect(SocketPathOwnershipStatus.missing(errnoCode: ENOENT).shouldAttemptListenerRecovery)
    #expect(SocketPathOwnershipStatus.missing(errnoCode: ENOTDIR).shouldAttemptListenerRecovery)
    #expect(!SocketPathOwnershipStatus.missing(errnoCode: EACCES).shouldAttemptListenerRecovery)
    #expect(!SocketPathOwnershipStatus.missing(errnoCode: EIO).shouldAttemptListenerRecovery)
    #expect(SocketPathOwnershipStatus.connectFailed(errnoCode: ECONNREFUSED).shouldAttemptListenerRecovery)
    #expect(SocketPathOwnershipStatus.connectFailed(errnoCode: ENOENT).shouldAttemptListenerRecovery)
    #expect(!SocketPathOwnershipStatus.connectFailed(errnoCode: ETIMEDOUT).shouldAttemptListenerRecovery)
    #expect(!SocketPathOwnershipStatus.connectFailed(errnoCode: EAGAIN).shouldAttemptListenerRecovery)
}

@Test func unlinkIfStaleSocketIdentityStableRemovesClosedSocket() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let path = root.appendingPathComponent("stale.sock").path
    let socketFD = try bindTestUnixSocket(at: path)
    let identity = try #require(SocketPathProbe.fileIdentity(path: path))
    close(socketFD)

    #expect(SocketPathProbe.unlinkIfStaleSocketIdentityStable(
        path,
        expectedIdentity: identity,
        expectedOwnerPID: getpid(),
        timeout: 0
    ) == 0)
    #expect(!FileManager.default.fileExists(atPath: path))
}

@Test func unlinkIfStaleSocketIdentityStableLeavesChangedPathAlone() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let pathURL = root.appendingPathComponent("changed.sock")
    let socketFD = try bindTestUnixSocket(at: pathURL.path)
    let identity = try #require(SocketPathProbe.fileIdentity(path: pathURL.path))
    close(socketFD)
    unlink(pathURL.path)
    try Data("replacement".utf8).write(to: pathURL)

    #expect(SocketPathProbe.unlinkIfStaleSocketIdentityStable(
        pathURL.path,
        expectedIdentity: identity,
        expectedOwnerPID: getpid(),
        timeout: 0
    ) == EBUSY)
    #expect(FileManager.default.fileExists(atPath: pathURL.path))
}

private func bindTestUnixSocket(at path: String) throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    try path.withCString { pathPointer in
        try withUnsafeMutablePointer(to: &addr.sun_path) { pathStorage in
            let raw = UnsafeMutableRawPointer(pathStorage).assumingMemoryBound(to: CChar.self)
            guard strlen(pathPointer) < MemoryLayout.size(ofValue: addr.sun_path) else {
                close(fd)
                throw POSIXError(.ENAMETOOLONG)
            }
            strcpy(raw, pathPointer)
        }
    }

    let bindResult = withUnsafePointer(to: &addr) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
            Darwin.bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard bindResult == 0 else {
        let code = errno
        close(fd)
        throw POSIXError(.init(rawValue: code) ?? .EIO)
    }

    guard listen(fd, 1) == 0 else {
        let code = errno
        close(fd)
        throw POSIXError(.init(rawValue: code) ?? .EIO)
    }

    return fd
}

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("CMUXSocketPathDomainTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
