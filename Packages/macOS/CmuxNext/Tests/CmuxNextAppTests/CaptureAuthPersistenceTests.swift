import Foundation
import Testing
@testable import CmuxNextCloud

struct CaptureAuthPersistenceTests {
    @Test func invalidLeaseIsRejectedBeforeStoreAccess() {
        let configuration = CloudConfiguration.unavailable
        let result = CaptureAuthPersistence().run(configuration: configuration, phase: .prepare,
                                                  leaseID: "wrong", requestedBundleIdentifier: configuration.bundleID ?? "")
        #expect(result == CaptureAuthCleanupResult(ok: false, code: .invalidLease))
    }

    @Test func existingExactCredentialFileRefusesPreparation() throws {
        let configuration = CloudConfiguration.unavailable
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let credentials = configuration.credentialsDirectory(homeDirectory: home).appendingPathComponent("credentials.json")
        try FileManager.default.createDirectory(at: credentials.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: credentials)
        defer { try? FileManager.default.removeItem(at: home) }

        let result = CaptureAuthPersistence().run(configuration: configuration, phase: .prepare,
                                                  leaseID: "0123456789abcdef01234567",
                                                  requestedBundleIdentifier: configuration.bundleID ?? "", homeDirectory: home)
        #expect(result == CaptureAuthCleanupResult(ok: false, code: .fileStorePresent))
    }

    @Test func cleanupRequiresMatchingLeaseMarker() throws {
        let configuration = CloudConfiguration.unavailable
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let marker = configuration.credentialsDirectory(homeDirectory: home).appendingPathComponent("capture-auth-lease")
        try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(("other-lease\n" + (configuration.bundleID ?? "")).utf8).write(to: marker)
        defer { try? FileManager.default.removeItem(at: home) }

        let result = CaptureAuthPersistence().run(configuration: configuration, phase: .cleanup,
                                                  leaseID: "0123456789abcdef01234567",
                                                  requestedBundleIdentifier: configuration.bundleID ?? "", homeDirectory: home)
        #expect(result == CaptureAuthCleanupResult(ok: false, code: .ownershipMismatch))
    }
}
