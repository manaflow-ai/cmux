import CmuxNextFiles
@testable import CmuxNextApp
import enum CmuxNextDaemon.DaemonError
import struct CmuxNextDaemon.FileSystemReadRequest
import struct CmuxNextDaemon.FileSystemReplaceRequest
import struct CmuxNextDaemon.FileSystemStatRequest
import protocol CmuxNextDaemonService.RemoteFileClient
import class CmuxNextDaemonService.RemoteFilePageFiles
import Foundation
import Testing

/// A Cloud chat's path chip reads the machine's file through no symlink (`fs-read-nofollow-v1`):
/// a link swapped in on the machine after ``RemoteFileClient/reachesThroughLink(_:)`` looked is
/// refused by the daemon at the read, and a save writes through none either. A folder path opens
/// the machine's folder in the Files tree, whose paths are never looked up on this Mac.
@MainActor
struct CloudPathNoFollowTests {
    /// One file on the machine. `swapped`: a link now stands where the stat saw a plain file, so a
    /// no-follow op is refused and a plain one reads the link's target. `noFollowServed` false: a
    /// daemon without the no-follow ops.
    final class Machine: RemoteFileClient {
        var text = "mine\n"
        var swapped = false
        var noFollowServed = true
        var asked: [String] = []

        func stat(_ path: String) async throws -> FileSystemStatRequest.Response {
            .init(kind: "file", size: UInt64(text.utf8.count), revision: "r1")
        }

        func read(_ path: String, maxBytes: Int) async throws -> FileSystemReadRequest.Response {
            asked.append("read")
            let bytes = swapped ? "secret\n" : text
            return .init(text: bytes, bytesBase64: nil, truncated: false, size: UInt64(bytes.utf8.count))
        }

        func readNoFollow(_ path: String, maxBytes: Int) async throws -> FileSystemReadRequest.Response {
            asked.append("readNoFollow")
            guard noFollowServed else { throw DaemonError.missingCapabilities(["fs-read-nofollow-v1"]) }
            if swapped { throw DaemonError.command(cmd: "fs.read", message: "a symlink is on the path", code: "fs.symlink_in_path") }
            return .init(text: text, bytesBase64: nil, truncated: false, size: UInt64(text.utf8.count))
        }

        func replace(_ path: String, text: String, expected: String) async throws -> FileSystemReplaceRequest.Response {
            asked.append("replace")
            return try Self.written()
        }

        func replaceNoFollow(_ path: String, text: String, expected: String) async throws -> FileSystemReplaceRequest.Response {
            asked.append("replaceNoFollow")
            guard noFollowServed else { throw DaemonError.missingCapabilities(["fs-write-nofollow-v1"]) }
            self.text = text
            return try Self.written()
        }

        static func written() throws -> FileSystemReplaceRequest.Response {
            try JSONDecoder().decode(FileSystemReplaceRequest.Response.self, from: Data(#"{"entry":{"revision":"r2"}}"#.utf8))
        }
    }

    private static let path = "/home/cmux/work/app/notes.md"

    @Test func aChipsFileIsReadAndSavedThroughNoLink() async throws {
        let machine = Machine()
        let files = RemoteFilePageFiles(client: machine, machine: "vm", noFollow: true)
        let snapshot = try await files.read(URL(fileURLWithPath: Self.path), inWorkspace: true)
        #expect(snapshot.text == "mine\n")
        _ = try await files.save("two\n", to: URL(fileURLWithPath: Self.path), baseHash: snapshot.hash, inWorkspace: true)
        #expect(machine.asked == ["readNoFollow", "readNoFollow", "replaceNoFollow"])
        #expect(machine.text == "two\n")
    }

    /// The link swapped in after the check: the daemon refuses the read, and nothing of the link's
    /// target reaches the page.
    @Test func aLinkSwappedInAfterTheCheckReadsNothing() async {
        let machine = Machine()
        machine.swapped = true
        let files = RemoteFilePageFiles(client: machine, machine: "vm", noFollow: true)
        do {
            _ = try await files.read(URL(fileURLWithPath: Self.path), inWorkspace: true)
            Issue.record("a swapped-in link was read through")
        } catch {
            if case .notFile = error {} else { Issue.record("refused as \(error), not as no file") }
        }
        #expect(!machine.asked.contains("read"))
    }

    /// A machine whose daemon predates the no-follow read reads as before (the chip's link check
    /// still ran), and never saves through a link.
    @Test func anOlderMachineReadsWithTheCheckAloneAndNeverSavesThroughALink() async throws {
        let machine = Machine()
        machine.noFollowServed = false
        let files = RemoteFilePageFiles(client: machine, machine: "vm", noFollow: true)
        let snapshot = try await files.read(URL(fileURLWithPath: Self.path), inWorkspace: true)
        #expect(snapshot.text == "mine\n")
        do {
            _ = try await files.save("two\n", to: URL(fileURLWithPath: Self.path), baseHash: snapshot.hash, inWorkspace: true)
            Issue.record("a save went with no no-follow write")
        } catch {}
        #expect(!machine.asked.contains("replace"))
    }

    /// Any other page of a machine's file follows links as before.
    @Test func aPlainMachineTabStillFollowsLinks() async throws {
        let machine = Machine()
        let files = RemoteFilePageFiles(client: machine, machine: "vm")
        _ = try await files.read(URL(fileURLWithPath: Self.path), inWorkspace: true)
        #expect(machine.asked == ["read"])
    }

    /// A folder chip opens the Files tree only when the stat says folder, and the daemon spells a
    /// folder `dir` on the wire (`EntryKind::Dir`).
    @Test func aFolderIsKnownByTheDaemonsOwnSpelling() throws {
        func kind(_ json: String) throws -> FileSystemStatRequest.Response {
            try JSONDecoder().decode(FileSystemStatRequest.Response.self, from: Data(json.utf8))
        }
        #expect(try kind(#"{"kind":"dir","revision":"r1"}"#).isFolder)
        #expect(try !kind(#"{"kind":"file","size":3,"revision":"r1"}"#).isFolder)
        #expect(try !kind(#"{"kind":"symlink","revision":"r1"}"#).isFolder)
    }

    /// A machine's folder in the Files tree: a path inside it is made by spelling, with no look at
    /// this Mac's disk (where no such folder exists), and a path that leaves it is refused.
    @Test func aMachineFoldersTreePathsAreCheckedBySpellingAlone() throws {
        let folder = URL(fileURLWithPath: "/home/cmux/work/app-\(UUID().uuidString)", isDirectory: true)
        let file = try FileTreePageProvider.resolve("src/main.rs", in: folder, onMachine: true)
        #expect(file.path == folder.path + "/src/main.rs")
        #expect(try FileTreePageProvider.resolve("", in: folder, onMachine: true) == folder)
        for outside in ["../x", "/etc/passwd", "a//b", "./a"] {
            #expect(throws: (any Error).self) { try FileTreePageProvider.resolve(outside, in: folder, onMachine: true) }
        }
    }
}
