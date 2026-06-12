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

private final class CapturingUpdateLog: UpdateLogging, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var messages: [String] = []

    func append(_ message: String) {
        lock.withLock {
            messages.append(message)
        }
    }

    func logPath() -> String { "/tmp/cmux-update-test.log" }
}

private struct PreflightFixture {
    let rootURL: URL
    let bundleURL: URL
    let bundle: Bundle
    let bundleIdentifier: String

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-updater-preflight-\(UUID().uuidString)", isDirectory: true)
        bundleURL = rootURL
            .appendingPathComponent("cmux.app", isDirectory: true)
        bundleIdentifier = "com.cmuxterm.test.\(UUID().uuidString)"

        let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleName": "cmux",
            "CFBundleExecutable": "cmux",
        ]
        let infoData = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try infoData.write(to: contentsURL.appendingPathComponent("Info.plist"))

        guard let loadedBundle = Bundle(url: bundleURL) else {
            throw FixtureError.bundleDidNotLoad
        }
        bundle = loadedBundle
    }

    var sparkleFrameworkURL: URL {
        bundleURL
            .appendingPathComponent("Contents/Frameworks/Sparkle.framework", isDirectory: true)
    }

    var sparkleCacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("org.sparkle-project.Sparkle", isDirectory: true)
    }

    enum FixtureError: Error {
        case bundleDidNotLoad
    }
}

private func setExtendedAttribute(_ name: String, value: String, at url: URL) throws {
    let bytes = Array(value.utf8)
    let result = bytes.withUnsafeBufferPointer { buffer in
        setxattr(url.path, name, buffer.baseAddress, buffer.count, 0, 0)
    }
    if result != 0 {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

private func hasExtendedAttribute(_ name: String, at url: URL) -> Bool {
    getxattr(url.path, name, nil, 0, 0, 0) >= 0
}
