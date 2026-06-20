import Testing
import Foundation
@testable import CmuxWindowing

@Suite("DeepLinkOpenPlanner")
@MainActor
struct DeepLinkOpenPlannerTests {
    private func makeTempDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("DeepLinkOpenPlannerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("partitions a shell script into a terminal request and a plain file into a preview path")
    func partitionsFiles() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let scriptURL = directory.appendingPathComponent("run.command", isDirectory: false)
        try "echo hi\n".data(using: .utf8)!.write(to: scriptURL)
        let textURL = directory.appendingPathComponent("notes.txt", isDirectory: false)
        try "hello\n".data(using: .utf8)!.write(to: textURL)

        let planner = DeepLinkOpenPlanner()
        let plan = planner.openPlan(
            externalFileURLs: [scriptURL, textURL],
            directories: ["/tmp/work"]
        )

        #expect(plan.terminalFileRequests.count == 1)
        #expect(plan.terminalFileRequests.first?.fileURL.lastPathComponent == "run.command")
        #expect(plan.filePreviewPaths == [textURL.path(percentEncoded: false)])
        #expect(plan.directories == ["/tmp/work"])
        #expect(!plan.isEmpty)
    }

    @Test("a terminal-eligible file never also appears as a preview path")
    func terminalFileExcludedFromPreview() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let scriptURL = directory.appendingPathComponent("tool.command", isDirectory: false)
        try "echo hi\n".data(using: .utf8)!.write(to: scriptURL)

        let plan = DeepLinkOpenPlanner().openPlan(externalFileURLs: [scriptURL], directories: [])

        #expect(plan.terminalFileRequests.count == 1)
        #expect(plan.filePreviewPaths.isEmpty)
    }

    @Test("an empty input yields an empty plan")
    func emptyInput() {
        let plan = DeepLinkOpenPlanner().openPlan(externalFileURLs: [], directories: [])
        #expect(plan.isEmpty)
        #expect(plan.terminalFileRequests.isEmpty)
        #expect(plan.filePreviewPaths.isEmpty)
        #expect(plan.directories.isEmpty)
    }

    @Test("directories pass through even when no files are present")
    func directoriesOnly() {
        let plan = DeepLinkOpenPlanner().openPlan(externalFileURLs: [], directories: ["/a", "/b"])
        #expect(plan.directories == ["/a", "/b"])
        #expect(!plan.isEmpty)
    }
}
