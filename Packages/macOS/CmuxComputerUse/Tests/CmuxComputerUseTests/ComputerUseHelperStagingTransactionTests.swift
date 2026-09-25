import Darwin
import Foundation
import Testing
@testable import CmuxComputerUse

struct ComputerUseHelperStagingTransactionTests {
    @Test func replacingReadOnlyOldGenerationPublishesOneNewHelper() throws {
        let fixture = try HelperBundleFixture()
        defer { fixture.remove() }
        let directory = fixture.root.appendingPathComponent("installed")
        let installed = directory.appendingPathComponent("cmux Computer Use.app")
        let staging = ComputerUseHelperStaging()
        try fixture.makeReadOnly(fixture.bundle)
        #expect(staging.install(nested: fixture.bundle, destination: installed, directory: directory) == installed)
        try Data("updated executable".utf8).write(to: fixture.executable)

        #expect(staging.install(nested: fixture.bundle, destination: installed, directory: directory) == installed)

        #expect(staging.isCurrent(nested: fixture.bundle, destination: installed))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).filter {
            $0.hasSuffix(".app")
        } == ["cmux Computer Use.app"])
        #expect(try FileManager.default.attributesOfItem(atPath: fixture.bundle.path)[.posixPermissions] as? Int == 0o555)
    }

    @Test(arguments: [HelperCopyFailureFileManager.Failure.copiedThenThrows, .copiedThenCancelled])
    func copyFailureAndCancellationCleanReadOnlyScratch(failure: HelperCopyFailureFileManager.Failure) async throws {
        let fixture = try HelperBundleFixture()
        defer { fixture.remove() }
        let directory = fixture.root.appendingPathComponent("installed")
        let installed = directory.appendingPathComponent("cmux Computer Use.app")
        try fixture.makeReadOnly(fixture.bundle)
        let result = await Task.detached { [bundle = fixture.bundle] in
            ComputerUseHelperStaging(fileManager: HelperCopyFailureFileManager(failure))
                .install(nested: bundle, destination: installed, directory: directory)
        }.value

        #expect(result == nil)
        #expect(try stagingNames(in: directory).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: installed.path))
    }

    @Test func permanentCleanupFailureCannotAllocateMoreThanOneScratchBundle() throws {
        let fixture = try HelperBundleFixture()
        defer { fixture.remove() }
        let directory = fixture.root.appendingPathComponent("installed")
        let installed = directory.appendingPathComponent("cmux Computer Use.app")
        let staging = ComputerUseHelperStaging(fileManager: HelperCopyFailureFileManager(.cleanupDenied))
        try fixture.makeReadOnly(fixture.bundle)

        for _ in 0 ..< 20 {
            #expect(staging.install(nested: fixture.bundle, destination: installed, directory: directory) == nil)
            #expect(try stagingNames(in: directory) == [ComputerUseHelperStaging.stagingName])
        }
        #expect(ComputerUseHelperStaging().reapOrphanedBundles(in: directory) == 1)
        #expect(try stagingNames(in: directory).isEmpty)
    }

    @Test func busyTransactionIsExcludedFromReaperAndOtherInstallers() throws {
        let fixture = try HelperBundleFixture()
        defer { fixture.remove() }
        let directory = fixture.root.appendingPathComponent("installed")
        let temporary = directory.appendingPathComponent(ComputerUseHelperStaging.stagingName)
        let staging = ComputerUseHelperStaging()
        try ComputerUseHelperDirectory().withExclusiveAccess(to: directory, createIfMissing: true) {
            try FileManager.default.copyItem(at: fixture.bundle, to: temporary)
            #expect(staging.reapOrphanedBundles(in: directory) == 0)
            #expect(staging.install(
                nested: fixture.bundle,
                destination: directory.appendingPathComponent("cmux Computer Use.app"),
                directory: directory
            ) == nil)
            #expect(FileManager.default.fileExists(atPath: temporary.path))
        }
        #expect(staging.reapOrphanedBundles(in: directory) == 1)
    }

    @Test func reaperDoesNotFollowLinksOrChangeTheirTargets() throws {
        let fixture = try HelperBundleFixture()
        defer { fixture.remove() }
        let directory = fixture.root.appendingPathComponent("installed")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".cmux Computer Use.\(UUID().uuidString).app")
        try FileManager.default.copyItem(at: fixture.bundle, to: temporary)
        let outside = fixture.root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("preserve".utf8).write(to: outside.appendingPathComponent("data"))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: outside.path)
        let link = temporary.appendingPathComponent("external")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let rootLink = directory.appendingPathComponent(".cmux Computer Use.\(UUID().uuidString).app")
        try FileManager.default.createSymbolicLink(at: rootLink, withDestinationURL: outside)
        try fixture.makeReadOnly(temporary)

        #expect(ComputerUseHelperStaging().reapOrphanedBundles(in: directory) == 1)

        #expect(try Data(contentsOf: outside.appendingPathComponent("data")) == Data("preserve".utf8))
        #expect(try FileManager.default.attributesOfItem(atPath: outside.path)[.posixPermissions] as? Int == 0o555)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: rootLink.path) == outside.path)
    }

    @Test func failedAtomicPublicationLeavesPreviousGenerationInPlace() throws {
        let fixture = try HelperBundleFixture()
        defer { fixture.remove() }
        let directory = fixture.root.appendingPathComponent("installed")
        let installed = directory.appendingPathComponent("cmux Computer Use.app")
        let staging = ComputerUseHelperStaging()
        #expect(staging.install(nested: fixture.bundle, destination: installed, directory: directory) == installed)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: installed.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: installed.path) }
        try Data("new generation".utf8).write(to: fixture.executable)

        #expect(staging.install(nested: fixture.bundle, destination: installed, directory: directory) == nil)

        #expect(try Data(contentsOf: installed.appendingPathComponent("Contents/MacOS/cmux-cua")) == Data("helper".utf8))
        #expect(try stagingNames(in: directory).isEmpty)
    }

    private func stagingNames(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).filter {
            $0.hasPrefix(".cmux Computer Use.") && $0.hasSuffix(".app")
        }.sorted()
    }
}
