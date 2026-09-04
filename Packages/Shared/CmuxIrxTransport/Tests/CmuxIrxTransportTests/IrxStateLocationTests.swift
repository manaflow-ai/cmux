import Foundation
import Testing

@testable import CmuxIrxTransport

/// State isolation regression (08-27 invisible-Mac incident): two builds or
/// two backends must never resolve the same state directory, and cache files
/// must be owner-only.
@Suite("state location")
struct IrxStateLocationTests {
    let base = URL(fileURLWithPath: "/tmp/base")

    @Test("different bundles and different brokers never share a directory")
    func isolation() {
        let nightlyProd = IrxStateLocation.directory(
            base: base, bundleIdentifier: "dev.cmux.app.nightly", brokerHost: "cmux.com")
        let devStaging = IrxStateLocation.directory(
            base: base, bundleIdentifier: "dev.cmux.app.debug.irx",
            brokerHost: "cmux-staging.vercel.app")
        let nightlyStaging = IrxStateLocation.directory(
            base: base, bundleIdentifier: "dev.cmux.app.nightly",
            brokerHost: "cmux-staging.vercel.app")
        #expect(nightlyProd != devStaging)
        #expect(nightlyProd != nightlyStaging)
        #expect(devStaging != nightlyStaging)
    }

    @Test("hostile identifiers sanitize without collapsing to a shared path")
    func sanitization() {
        #expect(IrxStateLocation.sanitized("../../etc", fallback: "x") == "..-..-etc")
        #expect(IrxStateLocation.sanitized("..", fallback: "x") == "x")
        #expect(IrxStateLocation.sanitized(".", fallback: "x") == "x")
        #expect(IrxStateLocation.sanitized(nil, fallback: "unknown-bundle") == "unknown-bundle")
        #expect(IrxStateLocation.sanitized("", fallback: "f") == "f")
        #expect(IrxStateLocation.sanitized("Dev.Cmux.App", fallback: "f") == "dev.cmux.app")
    }

    @Test("cache writes are owner-only for files and directories")
    func cachePermissions() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("irx-perms-\(UUID().uuidString)", isDirectory: true)
        let cache = IrxDiskCache<[String: String]>(
            fileURL: dir.appendingPathComponent("secrets.json"))
        cache.save(["token": "sensitive"])
        let filePerms = try FileManager.default.attributesOfItem(
            atPath: dir.appendingPathComponent("secrets.json").path
        )[.posixPermissions] as? Int
        let dirPerms = try FileManager.default.attributesOfItem(
            atPath: dir.path)[.posixPermissions] as? Int
        #expect(filePerms == 0o600)
        #expect(dirPerms == 0o700)
    }

    @Test("legacy shared directory is removed on sight")
    func legacyCleanup() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("irx-legacy-\(UUID().uuidString)", isDirectory: true)
        let legacy = base.appendingPathComponent("cmux-irx", isDirectory: true)
        try FileManager.default.createDirectory(
            at: legacy, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: legacy.appendingPathComponent("identity.json"))
        IrxStateLocation.removeLegacySharedDirectory(base: base)
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
    }
}
