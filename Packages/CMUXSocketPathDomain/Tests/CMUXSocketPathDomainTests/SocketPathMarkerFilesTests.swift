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

@Test func socketRecoveryOnlyAttemptsDefinitiveStaleConnectFailures() {
    #expect(SocketPathOwnershipStatus.connectFailed(errnoCode: ECONNREFUSED).shouldAttemptListenerRecovery)
    #expect(SocketPathOwnershipStatus.connectFailed(errnoCode: ENOENT).shouldAttemptListenerRecovery)
    #expect(!SocketPathOwnershipStatus.connectFailed(errnoCode: ETIMEDOUT).shouldAttemptListenerRecovery)
    #expect(!SocketPathOwnershipStatus.connectFailed(errnoCode: EAGAIN).shouldAttemptListenerRecovery)
}

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("CMUXSocketPathDomainTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
