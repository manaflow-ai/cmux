@testable import CmuxTerminalBackendService
import Darwin
import Foundation
import Testing

@Suite("Immutable terminal backend pair", .serialized)
struct BackendServicePairInstallerTests {
    @Test("daemon and renderer install as one exact immutable sibling pair")
    func installsExactPair() throws {
        let fixture = try PairFixture(buildID: buildID("1"), rendererContents: "renderer-v1")
        let pair = try fixture.installer.installBundledPair()

        #expect(pair.buildID == buildID("1"))
        #expect(pair.backendExecutableURL.deletingLastPathComponent() == pair.installationDirectoryURL)
        #expect(pair.rendererExecutableURL.deletingLastPathComponent() == pair.installationDirectoryURL)
        #expect(pair.rendererExecutableURL.lastPathComponent == "cmux-terminal-renderer")
        #expect(try String(contentsOf: pair.rendererExecutableURL, encoding: .utf8) == "renderer-v1")
        #expect(try fixture.installer.validateInstalledBackend(at: pair.backendExecutableURL) == pair)
    }

    @Test("renderer build identity must match the daemon")
    func rejectsMismatchedRendererBuildID() throws {
        let fixture = try PairFixture(buildID: buildID("2"))
        try (buildID("3") + "\n").write(
            to: fixture.inspection.rendererBuildIDURL,
            atomically: true,
            encoding: .utf8
        )

        #expect(throws: BackendServicePairError.self) {
            _ = try fixture.installer.installBundledPair()
        }
    }

    @Test("missing and symlinked renderers fail closed")
    func rejectsMissingOrSymlinkedRenderer() throws {
        let missing = try PairFixture(buildID: buildID("4"))
        try FileManager.default.removeItem(at: missing.inspection.rendererExecutableURL)
        #expect(throws: BackendServicePairError.self) {
            _ = try missing.installer.installBundledPair()
        }

        let linked = try PairFixture(buildID: buildID("5"))
        try FileManager.default.removeItem(at: linked.inspection.rendererExecutableURL)
        try FileManager.default.createSymbolicLink(
            at: linked.inspection.rendererExecutableURL,
            withDestinationURL: linked.inspection.executableURL
        )
        #expect(throws: BackendServicePairError.self) {
            _ = try linked.installer.installBundledPair()
        }
    }

    @Test("post-install tampering and unsafe modes fail closed")
    func rejectsTamperingAndUnsafeMode() throws {
        let tampered = try PairFixture(buildID: buildID("6"))
        let pair = try tampered.installer.installBundledPair()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: pair.rendererExecutableURL.path
        )
        try FileHandle(forWritingTo: pair.rendererExecutableURL).write(contentsOf: Data("tamper".utf8))
        #expect(throws: BackendServicePairError.self) {
            _ = try tampered.installer.validateInstalledPair(at: pair.installationDirectoryURL)
        }

        let writable = try PairFixture(buildID: buildID("7"))
        let writablePair = try writable.installer.installBundledPair()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o520],
            ofItemAtPath: writablePair.backendExecutableURL.path
        )
        #expect(throws: BackendServicePairError.self) {
            _ = try writable.installer.validateInstalledPair(at: writablePair.installationDirectoryURL)
        }
    }

    @Test("installed ownership is validated against the service user")
    func rejectsWrongOwner() throws {
        let fixture = try PairFixture(
            buildID: buildID("8"),
            expectedUserID: UInt32(geteuid()) + 1
        )
        #expect(throws: BackendServicePairError.self) {
            _ = try fixture.installer.installBundledPair()
        }
    }

    @Test("interrupted private staging directories are reaped without touching versions")
    func reapsOnlyStaleInstallDirectories() throws {
        let installRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-stale-install-\(UUID())", isDirectory: true)
        let versions = installRoot.appendingPathComponent("versions", isDirectory: true)
        try FileManager.default.createDirectory(
            at: versions,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: installRoot.path
        )
        let stale = versions.appendingPathComponent(".install-interrupted", isDirectory: true)
        let validVersion = versions.appendingPathComponent(buildID("c"), isDirectory: true)
        let unsafeStale = versions.appendingPathComponent(".install-unsafe", isDirectory: true)
        for directory in [stale, validVersion, unsafeStale] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stale.path)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: validVersion.path
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o720],
            ofItemAtPath: unsafeStale.path
        )
        let fixture = try PairFixture(
            buildID: buildID("d"),
            installationRoot: installRoot
        )

        _ = try fixture.installer.installBundledPair()

        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: validVersion.path))
        #expect(FileManager.default.fileExists(atPath: unsafeStale.path))
    }

    @Test("existing symlink install root is rejected without changing its target mode")
    func rejectsSymlinkRootWithoutMutatingTarget() throws {
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-symlink-install-\(UUID())", isDirectory: true)
        let target = fixtureRoot.appendingPathComponent("target", isDirectory: true)
        let linkedRoot = fixtureRoot.appendingPathComponent("install", isDirectory: true)
        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: target.path
        )
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: target)
        let fixture = try PairFixture(buildID: buildID("e"), installationRoot: linkedRoot)

        #expect(throws: BackendServicePairError.symbolicLink(linkedRoot)) {
            _ = try fixture.installer.installBundledPair()
        }
        let mode = try #require(
            FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber
        )
        #expect(mode.uint16Value & 0o777 == 0o755)
    }

    @Test("missing install hierarchy is created one private component at a time")
    func createsPrivateMissingHierarchy() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-private-hierarchy-\(UUID())", isDirectory: true)
        let first = base.appendingPathComponent("first", isDirectory: true)
        let second = first.appendingPathComponent("second", isDirectory: true)
        let installRoot = second.appendingPathComponent("install", isDirectory: true)
        let fixture = try PairFixture(buildID: buildID("f"), installationRoot: installRoot)

        _ = try fixture.installer.installBundledPair()

        for directory in [base, first, second, installRoot] {
            let mode = try #require(
                FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions]
                    as? NSNumber
            )
            #expect(mode.uint16Value & 0o777 == 0o700)
        }
    }

    private func buildID(_ nibble: Character) -> String {
        String(repeating: String(nibble), count: 64)
    }
}

struct PairFixture {
    let root: URL
    let inspection: BackendServiceBundleInspection
    let installer: BackendServicePairInstaller

    init(
        buildID: String,
        rendererContents: String = "renderer",
        installationRoot: URL? = nil,
        expectedUserID: UInt32 = UInt32(geteuid())
    ) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-pair-fixture-\(UUID())", isDirectory: true)
        let bundle = root.appendingPathComponent("cmux.app", isDirectory: true)
        let descriptor = BackendServiceDescriptor.production
        inspection = BackendServiceBundleInspection(bundleURL: bundle, descriptor: descriptor)
        try FileManager.default.createDirectory(
            at: inspection.propertyListURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("plist".utf8).write(to: inspection.propertyListURL)
        try FileManager.default.createDirectory(
            at: inspection.executableURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("backend".utf8).write(to: inspection.executableURL)
        try Data(rendererContents.utf8).write(to: inspection.rendererExecutableURL)
        for executable in [inspection.executableURL, inspection.rendererExecutableURL] {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: executable.path
            )
        }
        for sidecar in [inspection.backendBuildIDURL, inspection.rendererBuildIDURL] {
            try (buildID + "\n").write(
                to: sidecar,
                atomically: true,
                encoding: .utf8
            )
        }
        let installRoot = installationRoot ?? root.appendingPathComponent("install", isDirectory: true)
        installer = BackendServicePairInstaller(
            descriptor: descriptor,
            bundleInspection: inspection,
            installationRootURL: installRoot,
            expectedUserID: expectedUserID,
            buildIDReader: SidecarBuildIDReader(),
            codeSignatureValidator: AcceptingCodeSignatureValidator()
        )
    }
}

struct SidecarBuildIDReader: BackendServiceBuildIDReading {
    func buildID(reportedBy executableURL: URL) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: executableURL.path + ".build-id"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct AcceptingCodeSignatureValidator: BackendServiceCodeSignatureValidating {
    func validateCodeSignature(at _: URL, expectedIdentifier _: String) {}
}
