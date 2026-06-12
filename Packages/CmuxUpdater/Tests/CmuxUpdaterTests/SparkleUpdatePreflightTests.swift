import Darwin
import Foundation
import Testing
@testable import CmuxUpdater

@Suite struct SparkleUpdatePreflightTests {
    @Test func removesQuarantineFromBundledSparkleHelpers() throws {
        let fixture = try PreflightFixture()
        let helperURL = fixture.sparkleFrameworkURL
            .appendingPathComponent("Versions/B/Autoupdate")
        try FileManager.default.createDirectory(
            at: helperURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: helperURL.path, contents: Data())
        try setExtendedAttribute("com.apple.quarantine", value: "01c3;test;Safari;", at: helperURL)

        let log = CapturingUpdateLog()
        SparkleUpdatePreflight(
            hostBundle: fixture.bundle,
            fileManager: .default,
            log: log
        ).run()

        #expect(!hasExtendedAttribute("com.apple.quarantine", at: helperURL))
        #expect(log.messages.contains { $0.contains("Removed Sparkle quarantine attributes") })
    }

    @Test func removesEmptyInstallationDirectoryBeforeSparkleCreatesInstallSession() throws {
        let fixture = try PreflightFixture()
        let installationURL = fixture.sparkleCacheURL
            .appendingPathComponent("Installation", isDirectory: true)
        try FileManager.default.createDirectory(at: installationURL, withIntermediateDirectories: true)

        SparkleUpdatePreflight(
            hostBundle: fixture.bundle,
            fileManager: .default,
            log: CapturingUpdateLog()
        ).run()

        #expect(!FileManager.default.fileExists(atPath: installationURL.path))
    }
}
