import CoreServices
import Foundation
import Testing
@testable import CmuxComputerUse

struct ComputerUseRuntimeServiceTests {
    @Test func copiedHelperReleasesQuarantineWithoutFollowingSymlinks() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-computer-use-quarantine-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: root) }

        let helper = root.appendingPathComponent(
            "cmux Computer Use.app",
            isDirectory: true
        )
        let macOSDirectory = helper.appendingPathComponent(
            "Contents/MacOS",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: macOSDirectory,
            withIntermediateDirectories: true
        )
        let executable = macOSDirectory.appendingPathComponent("cmux-cua")
        try Data("helper".utf8).write(to: executable)

        let outside = root.appendingPathComponent("outside-helper")
        try Data("outside".utf8).write(to: outside)
        let symlink = macOSDirectory.appendingPathComponent("outside-link")
        try fileManager.createSymbolicLink(
            at: symlink,
            withDestinationURL: outside
        )

        for url in [
            helper,
            helper.appendingPathComponent("Contents", isDirectory: true),
            macOSDirectory,
            executable,
            outside,
        ] {
            try applyTestQuarantine(to: url)
        }

        try ComputerUseRuntimeService.releaseCopiedHelperFromQuarantine(
            at: helper,
            fileManager: fileManager
        )

        for url in [
            helper,
            helper.appendingPathComponent("Contents", isDirectory: true),
            macOSDirectory,
            executable,
        ] {
            #expect(try quarantineProperties(at: url) == nil)
        }
        #expect(try quarantineProperties(at: outside) != nil)
    }

    private func applyTestQuarantine(to url: URL) throws {
        var values = URLResourceValues()
        values.quarantineProperties = [
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
            kLSQuarantineTimeStampKey as String: Date(),
            kLSQuarantineAgentNameKey as String: "CmuxComputerUseTests",
        ]
        var mutableURL = url
        try mutableURL.setResourceValues(values)
    }

    private func quarantineProperties(at url: URL) throws -> [String: Any]? {
        try url.resourceValues(
            forKeys: [.quarantinePropertiesKey]
        ).quarantineProperties
    }
}
