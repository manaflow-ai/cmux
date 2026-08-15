import Darwin
import Foundation
import Testing

@testable import CmuxGit

@Suite struct WorkspaceChangesFingerprintTests {
    @Test func sameSizeSameMtimeReplacementChangesIdentityFingerprint() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-content-identity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let current = root.appendingPathComponent("current.txt")
        let replacement = root.appendingPathComponent("replacement.txt")
        let modifiedAt = Date(timeIntervalSince1970: 1_700_000_000)
        try Data("first".utf8).write(to: current)
        try Data("other".utf8).write(to: replacement)
        try FileManager.default.setAttributes(
            [.modificationDate: modifiedAt],
            ofItemAtPath: current.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: modifiedAt],
            ofItemAtPath: replacement.path
        )
        let reader = WorkspaceChangesContentReader()
        let before = try #require(reader.contentFingerprint(
            repoRoot: root.path,
            relativePath: current.lastPathComponent
        ))

        let renameResult = replacement.path.withCString { replacementPath in
            current.path.withCString { currentPath in
                Darwin.rename(replacementPath, currentPath)
            }
        }
        #expect(renameResult == 0)
        let after = try #require(reader.contentFingerprint(
            repoRoot: root.path,
            relativePath: current.lastPathComponent
        ))

        #expect(before.split(separator: ":").count == 6)
        #expect(after.split(separator: ":").count == 6)
        #expect(before != after)
    }
}
