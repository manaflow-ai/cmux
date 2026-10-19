import Darwin
import Foundation
import Testing
@testable import CmuxComputerUse

struct ComputerUseHelperQuarantineReleaseTests {
    @Test func quarantinedEntriesListsOnlyEntriesCarryingTheAttribute() throws {
        let fixture = try HelperBundleFixture()
        defer { fixture.remove() }
        let record = TestQuarantineAttribute.webDownloadRecord()
        try TestQuarantineAttribute.apply(record, to: fixture.bundle)
        try TestQuarantineAttribute.apply(record, to: fixture.executable)

        let entries = try ComputerUseHelperQuarantineRelease()
            .quarantinedEntries(treeAt: fixture.bundle)

        #expect(Set(entries.map(\.path)) == [fixture.bundle.path, fixture.executable.path])
    }

    @Test func releaseRemovesTheAttributeFromEveryEntryAndReportsEach() throws {
        let fixture = try HelperBundleFixture()
        defer { fixture.remove() }
        let record = TestQuarantineAttribute.webDownloadRecord()
        let entries = try fixture.bundleEntries()
        for entry in entries {
            try TestQuarantineAttribute.apply(record, to: entry)
        }

        let report = try ComputerUseHelperQuarantineRelease().release(treeAt: fixture.bundle)

        #expect(report.failures.isEmpty)
        #expect(Set(report.released.map(\.path)) == Set(entries.map(\.path)))
        for entry in entries {
            #expect(try TestQuarantineAttribute.record(at: entry) == nil, "\(entry.path)")
        }
        #expect(try ComputerUseHelperQuarantineRelease().quarantinedEntries(treeAt: fixture.bundle).isEmpty)
    }

    @Test func releaseLeavesACleanTreeUntouched() throws {
        let fixture = try HelperBundleFixture()
        defer { fixture.remove() }

        let report = try ComputerUseHelperQuarantineRelease().release(treeAt: fixture.bundle)

        #expect(report == ComputerUseHelperQuarantineRelease.Report())
        for entry in try fixture.bundleEntries() {
            #expect(try TestQuarantineAttribute.record(at: entry) == nil, "\(entry.path)")
        }
    }

    @Test func releaseSkipsSymbolicLinksWithoutFollowingThem() throws {
        let fixture = try HelperBundleFixture()
        defer { fixture.remove() }
        let fileManager = FileManager.default
        let record = TestQuarantineAttribute.webDownloadRecord()
        let outsideFile = fixture.root.appendingPathComponent("outside-file", isDirectory: false)
        try Data("outside".utf8).write(to: outsideFile)
        let outsideDirectory = fixture.root.appendingPathComponent("outside-dir", isDirectory: true)
        try fileManager.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
        let nestedOutsideFile = outsideDirectory.appendingPathComponent("nested", isDirectory: false)
        try Data("nested".utf8).write(to: nestedOutsideFile)
        let resources = fixture.hiddenMarker.deletingLastPathComponent()
        let fileLink = resources.appendingPathComponent("file-link", isDirectory: false)
        let directoryLink = resources.appendingPathComponent("dir-link", isDirectory: false)
        try fileManager.createSymbolicLink(at: fileLink, withDestinationURL: outsideFile)
        try fileManager.createSymbolicLink(at: directoryLink, withDestinationURL: outsideDirectory)
        for url in [outsideFile, outsideDirectory, nestedOutsideFile, fixture.executable] {
            try TestQuarantineAttribute.apply(record, to: url)
        }

        let report = try ComputerUseHelperQuarantineRelease().release(treeAt: fixture.bundle)

        #expect(report.failures.isEmpty)
        #expect(report.released.map(\.path) == [fixture.executable.path])
        #expect(try TestQuarantineAttribute.record(at: fixture.executable) == nil)
        for url in [outsideFile, outsideDirectory, nestedOutsideFile] {
            #expect(try TestQuarantineAttribute.record(at: url) == record, "\(url.path)")
        }
    }

    @Test func releaseContinuesPastAnEntryItCannotChangeAndReportsIt() throws {
        let fixture = try HelperBundleFixture()
        defer { fixture.remove() }
        let fileManager = FileManager.default
        let record = TestQuarantineAttribute.webDownloadRecord()
        let entries = try fixture.bundleEntries()
        for entry in entries {
            try TestQuarantineAttribute.apply(record, to: entry)
        }
        try fileManager.setAttributes([.immutable: true], ofItemAtPath: fixture.infoPlist.path)
        defer {
            try? fileManager.setAttributes([.immutable: false], ofItemAtPath: fixture.infoPlist.path)
        }

        let report = try ComputerUseHelperQuarantineRelease().release(treeAt: fixture.bundle)

        #expect(report.failures == [
            ComputerUseHelperQuarantineRelease.Failure(url: fixture.infoPlist, code: EPERM)
        ])
        #expect(
            Set(report.released.map(\.path))
                == Set(entries.map(\.path)).subtracting([fixture.infoPlist.path])
        )
        #expect(try TestQuarantineAttribute.record(at: fixture.infoPlist) == record)
        #expect(try TestQuarantineAttribute.record(at: fixture.executable) == nil)
    }

    @Test func releaseStopsWhenTheTaskIsCancelled() async throws {
        let fixture = try HelperBundleFixture()
        defer { fixture.remove() }
        let record = TestQuarantineAttribute.webDownloadRecord()
        try TestQuarantineAttribute.apply(record, to: fixture.executable)

        let bundle = fixture.bundle
        let outcome = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return Result {
                try ComputerUseHelperQuarantineRelease().release(treeAt: bundle)
            }
        }.value

        #expect(throws: CancellationError.self) { try outcome.get() }
        #expect(try TestQuarantineAttribute.record(at: fixture.executable) == record)
    }
}
