import Darwin
import Foundation
import Testing
@testable import CmuxComputerUse

/// Staged helper copies must never carry `com.apple.quarantine`, whatever the
/// bundled source carried: LaunchServices shows the first-open dialog for any
/// record on the copy, including the empty record Foundation's
/// `quarantineProperties = nil` writes on macOS 26.4.1 (#13803).
struct ComputerUseRuntimeServiceTests {
    @Test func releasingAQuarantinedHelperCopyRemovesTheAttributeWithoutFollowingSymlinks() throws {
        let fixture = try HelperBundleFixture()
        defer { fixture.remove() }
        let outside = fixture.root.appendingPathComponent("outside-helper", isDirectory: false)
        try Data("outside".utf8).write(to: outside)
        let link = fixture.executable
            .deletingLastPathComponent()
            .appendingPathComponent("outside-link", isDirectory: false)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let record = TestQuarantineAttribute.webDownloadRecord()
        for entry in try fixture.bundleEntries() where entry != link {
            try TestQuarantineAttribute.apply(record, to: entry)
        }
        try TestQuarantineAttribute.apply(record, to: outside)

        try ComputerUseHelperStaging().releaseCopiedHelperFromQuarantine(at: fixture.bundle)

        for entry in try fixture.bundleEntries() {
            #expect(try TestQuarantineAttribute.record(at: entry) == nil, "\(entry.path)")
        }
        #expect(try TestQuarantineAttribute.record(at: outside) == record)
    }

    @Test func releasingACleanHelperCopyLeavesNoAttributeBehind() throws {
        let fixture = try HelperBundleFixture()
        defer { fixture.remove() }
        for entry in try fixture.bundleEntries() {
            #expect(try TestQuarantineAttribute.record(at: entry) == nil, "\(entry.path)")
        }

        try ComputerUseHelperStaging().releaseCopiedHelperFromQuarantine(at: fixture.bundle)

        for entry in try fixture.bundleEntries() {
            #expect(try TestQuarantineAttribute.record(at: entry) == nil, "\(entry.path)")
        }
    }

    @Test func stagingACleanBundledHelperProducesAQuarantineFreeCopy() throws {
        let fixture = try HelperBundleFixture()
        defer { fixture.remove() }
        let directory = fixture.root.appendingPathComponent("staged", isDirectory: true)
        let destination = directory.appendingPathComponent(
            "cmux Computer Use.app",
            isDirectory: true
        )

        let installed = try #require(
            ComputerUseHelperStaging().install(
                nested: fixture.bundle,
                destination: destination,
                directory: directory
            )
        )

        #expect(installed == destination)
        let stagedEntries = try fixture.entries(of: destination)
        #expect(stagedEntries.count == (try fixture.bundleEntries().count))
        for entry in stagedEntries {
            #expect(try TestQuarantineAttribute.record(at: entry) == nil, "\(entry.path)")
        }
    }

    @Test func stagingAQuarantinedBundledHelperProducesAQuarantineFreeCopy() throws {
        let fixture = try HelperBundleFixture()
        defer { fixture.remove() }
        let record = TestQuarantineAttribute.webDownloadRecord(agent: "Homebrew")
        for entry in try fixture.bundleEntries() {
            try TestQuarantineAttribute.apply(record, to: entry)
        }
        let directory = fixture.root.appendingPathComponent("staged", isDirectory: true)
        let destination = directory.appendingPathComponent(
            "cmux Computer Use.app",
            isDirectory: true
        )

        let installed = try #require(
            ComputerUseHelperStaging().install(
                nested: fixture.bundle,
                destination: destination,
                directory: directory
            )
        )

        #expect(installed == destination)
        for entry in try fixture.entries(of: destination) {
            #expect(try TestQuarantineAttribute.record(at: entry) == nil, "\(entry.path)")
        }
        // Only the copy is released; the bundled source keeps its record.
        #expect(try TestQuarantineAttribute.record(at: fixture.executable) == record)
    }

    @Test func reapingStaleReadOnlyStagingBundlesLeavesTheInstalledHelperAlone() throws {
        let fixture = try HelperBundleFixture()
        defer { fixture.remove() }
        let fileManager = FileManager.default
        let directory = fixture.root.appendingPathComponent("staged", isDirectory: true)
        let stale = directory.appendingPathComponent(
            ".cmux Computer Use.\(UUID().uuidString).app",
            isDirectory: true
        )
        let installed = directory.appendingPathComponent(
            "cmux Computer Use.app",
            isDirectory: true
        )
        let unrelated = directory.appendingPathComponent(
            ".cmux Computer Use.not-a-uuid.app",
            isDirectory: true
        )
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.copyItem(at: fixture.bundle, to: stale)
        try fileManager.copyItem(at: fixture.bundle, to: installed)
        try fileManager.createDirectory(at: unrelated, withIntermediateDirectories: true)
        let staleEntries = try fixture.entries(of: stale)
        for entry in staleEntries {
            var metadata = stat()
            guard lstat(entry.path, &metadata) == 0 else { continue }
            if (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) {
                try fileManager.setAttributes(
                    [.posixPermissions: 0o555],
                    ofItemAtPath: entry.path
                )
            }
        }

        let removed = ComputerUseHelperStaging().reapOrphanedBundles(in: directory)

        #expect(removed == 1)
        #expect(!fileManager.fileExists(atPath: stale.path))
        #expect(fileManager.fileExists(atPath: installed.path))
        #expect(fileManager.fileExists(atPath: unrelated.path))
    }

    @Test func failedInstallAttemptsDoNotAccumulateStagingBundles() throws {
        let fixture = try HelperBundleFixture()
        let fileManager = FileManager.default
        let directory = fixture.root.appendingPathComponent("staged", isDirectory: true)
        let destinationParent = fixture.root.appendingPathComponent("installed", isDirectory: true)
        let destination = destinationParent.appendingPathComponent(
            "cmux Computer Use.app",
            isDirectory: true
        )
        try fileManager.createDirectory(at: destinationParent, withIntermediateDirectories: true)
        try fileManager.setAttributes(
            [.posixPermissions: 0o555],
            ofItemAtPath: destinationParent.path
        )
        for entry in try fixture.bundleEntries() {
            var metadata = stat()
            guard lstat(entry.path, &metadata) == 0 else { continue }
            if (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) {
                try fileManager.setAttributes(
                    [.posixPermissions: 0o555],
                    ofItemAtPath: entry.path
                )
            }
        }
        defer {
            if let enumerator = fileManager.enumerator(
                at: fixture.root,
                includingPropertiesForKeys: []
            ) {
                for case let entry as URL in enumerator {
                    var metadata = stat()
                    guard lstat(entry.path, &metadata) == 0 else { continue }
                    if (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) {
                        _ = chmod(entry.path, mode_t(0o755))
                    }
                }
            }
            _ = chmod(destinationParent.path, mode_t(0o755))
            _ = chmod(fixture.root.path, mode_t(0o755))
            fixture.remove()
        }

        for _ in 0 ..< 8 {
            #expect(
                ComputerUseHelperStaging().install(
                    nested: fixture.bundle,
                    destination: destination,
                    directory: directory
                ) == nil
            )
        }

        let orphanedBundles = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ).filter { url in
            url.lastPathComponent.hasPrefix(".cmux Computer Use.")
                && url.pathExtension == "app"
        }
        #expect(orphanedBundles.isEmpty)
    }
}
