import Darwin
import Foundation
import Testing
@testable import CmuxComputerUse

@MainActor
struct ComputerUseHelperLifecycleTests {
    @Test func failedVerificationBacksOffThenReusesTheInstalledGeneration() async throws {
        let fixture = try HelperRuntimeFixture()
        defer { fixture.files.remove() }
        let executable = fixture.nestedHelper.appendingPathComponent("Contents/MacOS/cmux-cua")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: executable.path)
        try fixture.files.makeReadOnly(fixture.nestedHelper)
        var uptime: TimeInterval = 100
        let runtime = ComputerUseRuntimeService(
            bundle: fixture.bundle, paths: fixture.paths, uptime: { uptime }, isDisabledByPolicy: { false }
        )
        defer { runtime.stopForTermination() }

        #expect(await runtime.ensureStandaloneHelperInstalled() == nil)
        // Repair the real source. Calls before the deadline must not perform
        // another copy even though a fresh install would now succeed.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        for _ in 0 ..< 10 {
            #expect(await runtime.ensureStandaloneHelperInstalled() == nil)
        }
        #expect(try applicationNames(in: fixture.paths.installedHelperDirectoryURL).isEmpty)
        uptime = 105
        let installed = try #require(await runtime.ensureStandaloneHelperInstalled())
        let originalInode = try inode(at: installed)
        for _ in 0 ..< 8 {
            #expect(await runtime.ensureStandaloneHelperInstalled() == installed)
            #expect(try inode(at: installed) == originalInode)
        }
        #expect(try applicationNames(in: fixture.paths.installedHelperDirectoryURL) == ["cmux Computer Use.app"])
    }

    @Test func startupAndLaterMaintenanceRemoveReadOnlyOrphansWhenDisabled() async throws {
        let fixture = try HelperRuntimeFixture()
        defer { fixture.files.remove() }
        let directory = fixture.paths.installedHelperDirectoryURL
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stale = directory.appendingPathComponent(".cmux Computer Use.\(UUID().uuidString).app")
        try FileManager.default.copyItem(at: fixture.files.bundle, to: stale)
        try fixture.files.makeReadOnly(stale)
        let runtime = ComputerUseRuntimeService(bundle: fixture.bundle, paths: fixture.paths)
        defer { runtime.stopForTermination() }

        // Both startup and the cancellable maintenance scheduler use this same
        // serialized operation, independent of the Computer Use enabled state.
        await runtime.reapOrphanedHelperStaging()
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        let later = directory.appendingPathComponent(ComputerUseHelperStaging.stagingName)
        try FileManager.default.copyItem(at: fixture.files.bundle, to: later)
        try fixture.files.makeReadOnly(later)
        await runtime.reapOrphanedHelperStaging()
        #expect(!FileManager.default.fileExists(atPath: later.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.paths.authenticationTokenFileURL.path))
        #expect(runtime.helperAppURL == nil)
    }

    @Test func cleanProfileCreatesTheEntireHelperHierarchy() throws {
        let fixture = try HelperRuntimeFixture()
        defer { fixture.files.remove() }
        let runtime = ComputerUseRuntimeService(bundle: fixture.bundle, paths: fixture.paths)
        defer { runtime.stopForTermination() }
        #expect(runtime.prepareRuntimeForLaunch())
        #expect(FileManager.default.fileExists(atPath: fixture.paths.installedHelperDirectoryURL.path))
    }

    @Test func startupRejectsSymlinkedHelperAncestor() async throws {
        let fixture = try HelperRuntimeFixture()
        defer { fixture.files.remove() }
        let outside = fixture.files.root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let root = fixture.paths.computerUseDirectoryURL
        try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: outside)
        let before = try FileManager.default.attributesOfItem(atPath: outside.path)[.posixPermissions] as? Int
        let runtime = ComputerUseRuntimeService(bundle: fixture.bundle, paths: fixture.paths)
        defer { runtime.stopForTermination() }

        await runtime.reapOrphanedHelperStaging()

        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        #expect(try FileManager.default.attributesOfItem(atPath: outside.path)[.posixPermissions] as? Int == before)
    }

    private func applicationNames(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".app") }.sorted()
    }

    private func inode(at url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require((attributes[.systemFileNumber] as? NSNumber)?.uint64Value)
    }
}
