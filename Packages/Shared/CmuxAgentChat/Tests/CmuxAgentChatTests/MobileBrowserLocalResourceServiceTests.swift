import CMUXMobileCore
import Foundation
import Testing

@testable import CmuxAgentChat

@Suite("MobileBrowserLocalResourceService")
struct MobileBrowserLocalResourceServiceTests {
    @Test("fetches a bounded HTML range with MIME metadata")
    func fetchesBoundedRange() throws {
        try withTemporaryDirectory { root in
            let file = root.appendingPathComponent("index.html")
            try Data("<h1>hello</h1>".utf8).write(to: file)
            #expect(FileManager.default.fileExists(atPath: file.path))
            let directStat = try ArtifactByteReader().stat(path: file.path)
            #expect(directStat.size == 14)
            let directChunk = try ArtifactByteReader().fetch(path: file.path, offset: 0, length: 4)
            #expect(directChunk.data == Data("<h1>".utf8))

            let chunk = try MobileBrowserLocalResourceService().fetch(
                path: "/index.html",
                readRoot: root,
                offset: 0,
                length: 4
            )

            #expect(chunk.path == "/index.html")
            #expect(chunk.data == Data("<h1>".utf8))
            #expect(chunk.totalSize == 14)
            #expect(chunk.mimeType == "text/html")
            #expect(!chunk.eof)
        }
    }

    @Test("rejects traversal outside the WebKit read root")
    func rejectsTraversal() throws {
        try withTemporaryDirectory { root in
            #expect(throws: MobileBrowserLocalResourceService.Error.invalidPath) {
                try MobileBrowserLocalResourceService().fetch(
                    path: "/../outside.html",
                    readRoot: root,
                    offset: 0,
                    length: 1
                )
            }
        }
    }

    @Test("enforces the per-resource byte budget before reading")
    func enforcesResourceBudget() throws {
        try withTemporaryDirectory { root in
            let file = root.appendingPathComponent("large.html")
            try Data(repeating: 0x61, count: 5).write(to: file)
            let policy = MobileBrowserLocalResourcePolicy(
                maximumResourceBytes: 4,
                maximumPageBytes: 4,
                maximumChunkBytes: 2
            )

            #expect(throws: MobileBrowserLocalResourceService.Error.tooLarge) {
                try MobileBrowserLocalResourceService(policy: policy).fetch(
                    path: "/large.html",
                    readRoot: root,
                    offset: 0,
                    length: 5
                )
            }
        }
    }

    private func withTemporaryDirectory(_ operation: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-mobile-browser-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try operation(directory)
    }
}
