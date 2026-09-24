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

        try ComputerUseRuntimeService.releaseCopiedHelperFromQuarantine(
            at: fixture.bundle,
            fileManager: .default
        )

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

        try ComputerUseRuntimeService.releaseCopiedHelperFromQuarantine(
            at: fixture.bundle,
            fileManager: .default
        )

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
            ComputerUseRuntimeService.installHelper(
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
            ComputerUseRuntimeService.installHelper(
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
}
