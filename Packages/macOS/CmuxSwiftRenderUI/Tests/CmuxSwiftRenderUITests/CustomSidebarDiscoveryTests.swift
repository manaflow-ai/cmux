import Foundation
import Testing
@testable import CmuxSwiftRenderUI

@Suite(.timeLimit(.minutes(1)))
struct CustomSidebarDiscoveryTests {
    @Test
    func observesExternalCreationRenameDeletionAndDirectoryReplacement() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("sidebars")
        let discovery = CustomSidebarDiscovery(directory: directory)
        var updates = await discovery.updates().makeAsyncIterator()
        #expect(await updates.next() == [])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let first = directory.appendingPathComponent("one.swift")
        try "Text(\"One\")".write(to: first, atomically: true, encoding: .utf8)
        try await expect(["one"], from: &updates)
        let renamed = directory.appendingPathComponent("two.swift")
        try FileManager.default.moveItem(at: first, to: renamed)
        try await expect(["two"], from: &updates)
        try FileManager.default.removeItem(at: renamed)
        try await expect([], from: &updates)
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "Text(\"Recreated\")".write(to: first, atomically: true, encoding: .utf8)
        try await expect(["one"], from: &updates)
    }

    private func expect(_ names: [String], from updates: inout AsyncStream<[String]>.Iterator) async throws {
        while let snapshot = await updates.next() {
            if snapshot == names { return }
        }
        Issue.record("Discovery ended before observing \(names)")
    }
}
