import Foundation
import Testing

@testable import CmuxAgentChat

@Suite("Chat artifact canonical identity")
struct ChatArtifactCanonicalIdentityTests {
    @Test("derive accepts an injected canonical identity operation")
    func injectedCanonicalizerDeduplicates() {
        let target = "/fixture/Report.md"
        let symlink = "/fixture/report-link.md"
        let canonical = "/canonical/Report.md"
        let canonicalizer = ChatArtifactPathCanonicalizer { path in
            [target: canonical, symlink: canonical][path] ?? path
        }

        let records = ChatArtifactIndexedReference.derive(
            from: [
                editMessage(id: "created", seq: 4, path: target),
                toolMessage(id: "referenced", seq: 9, path: symlink),
            ],
            canonicalizer: canonicalizer
        )

        #expect(records == [ChatArtifactIndexedReference(
            path: canonical,
            provenance: .created,
            lastReferencedSeq: 9
        )])
    }

    @Test("symlink and target spellings produce one row")
    func symlinkAndTargetDeduplicate() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("Report.txt")
        let symlink = root.appendingPathComponent("report-link.txt")
        try Data("report".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)

        let records = ChatArtifactIndexedReference.derive(from: [
            toolMessage(id: "target", seq: 1, path: target.path),
            toolMessage(id: "symlink", seq: 2, path: symlink.path),
        ])

        #expect(records == [ChatArtifactIndexedReference(
            path: try lexicalPath(target.path),
            provenance: .referenced,
            lastReferencedSeq: 2
        )])
    }

    @Test("case variants produce one row with the on-disk spelling")
    func caseVariantsUseOnDiskSpelling() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let onDisk = root.appendingPathComponent("MixedCaseReport.TXT")
        let variant = root.appendingPathComponent("mixedcasereport.txt")
        try Data("report".utf8).write(to: onDisk)
        #expect(FileManager.default.fileExists(atPath: variant.path))

        let records = ChatArtifactIndexedReference.derive(from: [
            toolMessage(id: "canonical-case", seq: 1, path: onDisk.path),
            toolMessage(id: "variant-case", seq: 2, path: variant.path),
        ])

        #expect(records == [ChatArtifactIndexedReference(
            path: try lexicalPath(onDisk.path),
            provenance: .referenced,
            lastReferencedSeq: 2
        )])
    }

    @Test("a deleted file remains listed under its lexical path")
    func deletedFileRemainsLexical() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let deleted = root.appendingPathComponent("DeletedReport.TXT")
        try Data("report".utf8).write(to: deleted)
        try FileManager.default.removeItem(at: deleted)

        let records = ChatArtifactIndexedReference.derive(from: [
            toolMessage(id: "deleted", seq: 3, path: deleted.path),
        ])

        #expect(records == [ChatArtifactIndexedReference(
            path: try lexicalPath(deleted.path),
            provenance: .referenced,
            lastReferencedSeq: 3
        )])
    }

    @Test("created provenance survives a later symlink reference and advances sequence")
    func provenanceAndSequenceMergeAcrossSpellings() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("Created.swift")
        let symlink = root.appendingPathComponent("created-link.swift")
        try Data("let value = 1".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)

        let records = ChatArtifactIndexedReference.derive(from: [
            editMessage(id: "created", seq: 4, path: target.path),
            toolMessage(id: "referenced", seq: 9, path: symlink.path),
        ])

        #expect(records == [ChatArtifactIndexedReference(
            path: try lexicalPath(target.path),
            provenance: .created,
            lastReferencedSeq: 9
        )])
    }

    @Test("chip session total matches the deduplicated gallery total")
    func chipTotalMatchesDeduplicatedGallery() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("ChipCount.md")
        let symlink = root.appendingPathComponent("chip-count-link.md")
        try Data("count".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)
        let records = ChatArtifactIndexedReference.derive(from: [
            toolMessage(id: "target", seq: 1, path: target.path),
            toolMessage(id: "symlink", seq: 2, path: symlink.path),
        ])

        let total = ChatArtifactGalleryOrdering().sessionTotal(records)

        #expect(total == records.count)
        #expect(total == 1)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-artifact-identity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func lexicalPath(_ path: String) throws -> String {
        try #require(ChatArtifactPathNormalizer(workingDirectory: nil).structuredPath(path))
    }

    private func toolMessage(id: String, seq: Int, path: String) -> ChatMessage {
        ChatMessage(
            id: id,
            seq: seq,
            role: .agent,
            timestamp: Date(timeIntervalSince1970: 0),
            kind: .toolUse(ChatToolUse(
                toolName: "Read",
                summary: "read",
                status: .succeeded,
                referencedPaths: [path]
            ))
        )
    }

    private func editMessage(id: String, seq: Int, path: String) -> ChatMessage {
        ChatMessage(
            id: id,
            seq: seq,
            role: .agent,
            timestamp: Date(timeIntervalSince1970: 0),
            kind: .fileEdit(ChatFileEdit(filePath: path, operation: .write))
        )
    }
}
