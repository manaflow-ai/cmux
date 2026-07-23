import Foundation
@testable import CmuxArtifacts

struct ArtifactTestSupport {
    private init() {}

    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CmuxArtifactsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func write(_ contents: String, named name: String, under directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name, isDirectory: false)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    static func runGit(_ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    static func artifactNode(
        root: URL,
        relativePath: String,
        kind: ArtifactFileKind
    ) -> ArtifactNode {
        ArtifactNode(
            id: relativePath,
            name: URL(fileURLWithPath: relativePath).lastPathComponent,
            relativePath: relativePath,
            absolutePath: root.appendingPathComponent(".cmux/\(relativePath)").path,
            isDirectory: false,
            fileKind: kind,
            size: 1,
            modifiedAt: nil,
            children: []
        )
    }

    static func artifactFolder(
        root: URL,
        relativePath: String,
        children: [ArtifactNode]
    ) -> ArtifactNode {
        ArtifactNode(
            id: relativePath,
            name: URL(fileURLWithPath: relativePath).lastPathComponent,
            relativePath: relativePath,
            absolutePath: root.appendingPathComponent(".cmux/\(relativePath)").path,
            isDirectory: true,
            fileKind: nil,
            size: nil,
            modifiedAt: nil,
            children: children
        )
    }
}
