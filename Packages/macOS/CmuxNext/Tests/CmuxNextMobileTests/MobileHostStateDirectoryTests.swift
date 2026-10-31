import Foundation
import Testing
@testable import CmuxNextMobile

/// The pre-rename state folder (`cnx-host`) moves to `cmux-mobile-host`, so phones paired
/// with an earlier build stay paired.
@Suite struct MobileHostStateDirectoryTests {
    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MobileHostStateDirectoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func movesThePreRenameFolder() throws {
        let parent = try scratch()
        defer { try? FileManager.default.removeItem(at: parent) }
        let legacy = parent.appendingPathComponent("cnx-host", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("paired".utf8).write(to: legacy.appendingPathComponent("paired-devices.json"))

        let state = MobileHostStateDirectory(parent: parent).resolve()

        #expect(state.lastPathComponent == "cmux-mobile-host")
        #expect(try Data(contentsOf: state.appendingPathComponent("paired-devices.json")) == Data("paired".utf8))
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
    }

    @Test func keepsTheCurrentFolderWhenBothExist() throws {
        let parent = try scratch()
        defer { try? FileManager.default.removeItem(at: parent) }
        let current = parent.appendingPathComponent("cmux-mobile-host", isDirectory: true)
        let legacy = parent.appendingPathComponent("cnx-host", isDirectory: true)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: current.appendingPathComponent("device-id"))

        #expect(MobileHostStateDirectory(parent: parent).resolve() == current)
        #expect(try Data(contentsOf: current.appendingPathComponent("device-id")) == Data("new".utf8))
    }
}
