@testable import CmuxNextApp
// Only the daemon types the fake answers with: CmuxNextDaemon's JSONValue would shadow the pages' one.
import enum CmuxNextDaemon.DaemonError
import struct CmuxNextDaemon.FileSystemReadRequest
import struct CmuxNextDaemon.FileSystemReplaceRequest
import struct CmuxNextDaemon.FileSystemStatRequest
import CmuxNextDesign
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// The file viewer in a Cloud workspace (#25581): a markdown or editor tab of a file on another
/// machine reads, saves and watches that machine's file through its daemon (`fs-v1`), never a
/// file of the same path on this Mac, follows changes made there, and says clearly when the
/// machine cannot answer. Before, every file page read this Mac's disk, and a Cloud terminal's
/// paths did not open at all.
@MainActor
@Suite(.serialized)
struct CloudFileViewerTests {
    static let machine = "dev-vm"

    /// A machine's files as its daemon serves them: each path's text and revision. `offline`
    /// answers as a link that did not open; `served` false as a daemon without `fs-v1`. A path in
    /// `links` is a symlink to another path, as the daemon treats one: a stat answers the link's
    /// own revision, a read and a write follow it, and a write checks the target's revision.
    /// `staleRead` is what every read returns while the VM writes the file again during it (a
    /// read that races a write); `writeCap` refuses larger writes.
    final class MachineFiles: RemoteFileClient {
        var files: [String: (text: String, revision: Int)] = [:]
        var links: [String: String] = [:]
        var offline = false
        var served = true
        var staleRead: String?
        var writeCap = Int.max
        var writes: [(String, String, String)] = []

        func set(_ path: String, _ text: String) {
            files[path] = (text, (files[path]?.revision ?? 0) + 1)
        }

        private func target(_ path: String) -> String { links[path] ?? path }

        private func check(_ path: String) throws {
            if offline { throw DaemonError.notConnected }
            if !served { throw DaemonError.missingCapabilities(["fs-v1"]) }
            guard files[target(path)] != nil else {
                throw DaemonError.command(cmd: "fs", message: "not found", code: "fs.not_found")
            }
        }

        func stat(_ path: String) async throws -> FileSystemStatRequest.Response {
            try check(path)
            if links[path] != nil { return .init(kind: "symlink", size: 10, revision: "link1") }
            let file = files[path]!
            return .init(kind: "file", size: UInt64(file.text.utf8.count), revision: "r\(file.revision)")
        }

        func read(_ path: String, maxBytes: Int) async throws -> FileSystemReadRequest.Response {
            try check(path)
            let file = files[target(path)]!
            if let staleRead {
                set(target(path), file.text + "+")
                return .init(text: staleRead, bytesBase64: nil, truncated: false, size: UInt64(staleRead.utf8.count))
            }
            return .init(text: file.text, bytesBase64: nil, truncated: false, size: UInt64(file.text.utf8.count))
        }

        func replace(_ path: String, text: String, expected: String) async throws -> FileSystemReplaceRequest.Response {
            try check(path)
            let real = target(path)
            guard text.utf8.count <= writeCap else {
                throw DaemonError.command(cmd: "fs.write", message: "too large", code: "fs.too_large")
            }
            guard "r\(files[real]!.revision)" == expected else {
                throw DaemonError.command(cmd: "fs.write", message: "changed", code: "fs.revision_mismatch",
                                          details: .object(["current": .string("r\(files[real]!.revision)")]))
            }
            writes.append((path, text, expected))
            set(real, text)
            return try JSONDecoder().decode(FileSystemReplaceRequest.Response.self,
                                            from: Data(#"{"entry":{"revision":"r\#(files[real]!.revision)"}}"#.utf8))
        }
    }

    private final class Host: FilePageHosting {
        var roots: FileWorkspaceRoots { FileWorkspaceRoots(folders: []) }
        var remoteImages: Bool { false }
        var recorded: [URL] = []
        var saves: [URL] = []
        func recents() -> JSONValue { ["items": []] }
        func record(_ url: URL) { recorded.append(url) }
        func chooseFile(start: URL?) async -> URL? { nil }
        func look() -> JSONValue { .object([:]) }
        func listenLook(_ onLook: @escaping @MainActor (JSONValue) -> Void) -> () -> Void { {} }
        func setPreference(key: String, value: JSONValue, by writer: SettingWriter) async throws {}
        func opened(_ url: URL) {}
        func openExternal(_ url: URL) {}
        func openFile(_ url: URL) {}
        func openAppLink(_ url: URL) -> Bool { false }
        func isRecent(_ path: String) -> Bool { false }
        func confirmOpen(_ url: URL, userGesture: Bool) async -> Bool { false }
        func edited(_ url: URL, text: String, baseHash: String?, writable: Bool) -> RecoveryDraftAcceptance { .kept }
        func saved(_ url: URL, hash: String) { saves.append(url) }
    }

    private final class NoImages: RemoteImageFetching {
        func fetch(_ url: URL) async -> PageResource? { nil }
    }

    private static func call(_ provider: FilePageProvider, _ name: String, _ params: JSONValue = .object([:])) async throws -> JSONValue {
        try await provider.call("\(provider.kind.namespace).\(name)", params: params, context: PageCallContext(page: provider.kind.namespace))
    }

    @Test func aCloudTabShowsTheMachinesFileNotThisMacsCopy() async throws {
        // A file of the same path exists on this Mac with other text.
        let folder = FileManager.default.temporaryDirectory.appending(path: "cloud-file-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "notes.md").standardizedFileURL
        try Data("# This Mac\n".utf8).write(to: url)
        let machine = MachineFiles()
        machine.set(url.path, "# The VM\n")
        let host = Host()
        let provider = FilePageProvider(kind: .markdown, file: url, host: host, libraries: nil, images: NoImages(),
                                        files: RemoteFilePageFiles(client: machine, machine: Self.machine))
        let config = try await Self.call(provider, "config")
        #expect(config["text"]?.stringValue == "# The VM\n")
        #expect(config["readOnly"] == nil)
        // Nothing beside the file is read from this Mac: no folder images, no git remote.
        #expect(config["assetBase"] == nil)
        #expect(config["githubRepository"] == nil)
        // Links resolve against this Mac's folders: another machine's file gets none.
        let links = try await Self.call(provider, "resolveLinks", ["from": .string(url.path), "paths": ["other.md"]])
        #expect(links["links"]?.objectValue?.isEmpty == true)
        provider.close()
    }

    @Test func aSaveReplacesTheMachinesFileOnlyAtTheRevisionItShowed() async throws {
        let path = "/home/cmux/notes.md"
        let machine = MachineFiles()
        machine.set(path, "one\n")
        let host = Host()
        let provider = FilePageProvider(kind: .markdown, file: URL(fileURLWithPath: path), host: host, libraries: nil, images: NoImages(),
                                        files: RemoteFilePageFiles(client: machine, machine: Self.machine))
        let config = try await Self.call(provider, "config")
        let base = try #require(config["hash"]?.stringValue)
        let saved = try await Self.call(provider, "save", ["path": .string(path), "text": "two\n", "baseHash": .string(base)])
        #expect(machine.files[path]?.text == "two\n")
        #expect(machine.writes.map(\.2) == ["r1"])
        // This Mac's quit documents and git state are not told about another machine's file.
        #expect(host.saves.isEmpty)
        // Someone on the VM edits it: a save on the old text is a conflict carrying the VM's text.
        machine.set(path, "three\n")
        do {
            _ = try await Self.call(provider, "save", ["path": .string(path), "text": "mine\n", "baseHash": saved["hash"] ?? .null])
            Issue.record("a stale save replaced the machine's file")
        } catch let error as PageError {
            #expect(error.code == "cmux.markdown.conflict")
            #expect(error.details?["text"]?.stringValue == "three\n")
        }
        #expect(machine.files[path]?.text == "three\n")
        provider.close()
    }

    @Test func aCloudTabFollowsChangesOnTheMachineAndSaysWhenItIsGone() async throws {
        let path = "/home/cmux/notes.md"
        let machine = MachineFiles()
        machine.set(path, "one\n")
        let files = RemoteFilePageFiles(client: machine, machine: Self.machine)
        var changes: [FileSnapshot?] = []
        var notices: [String?] = []
        let watch = try #require(files.watch(URL(fileURLWithPath: path), inWorkspace: { true }, clock: ContinuousClock(),
                                             onChange: { changes.append($0) },
                                             onUnavailable: { notices.append($0) }) as? RemoteFileChangeWatch)
        watch.knownHash = FileDocument.hash(Data("one\n".utf8))
        // Unchanged: nothing is reported.
        await watch.check()
        #expect(changes.isEmpty)
        // Written on the VM: the new text.
        machine.set(path, "two\n")
        await watch.check()
        #expect(changes.compactMap { $0?.text } == ["two\n"])
        // The machine drops off: one notice naming it, not a deletion.
        machine.offline = true
        await watch.check()
        await watch.check()
        #expect(notices.count == 1)
        #expect(notices.first??.contains(Self.machine) == true)
        #expect(changes.count == 1)
        // Back with a change made meanwhile: the notice clears and the change arrives.
        machine.offline = false
        machine.set(path, "three\n")
        await watch.check()
        #expect(notices.last == .some(nil))
        #expect(changes.last??.text == "three\n")
        // Deleted on the VM.
        machine.files[path] = nil
        await watch.check()
        #expect(changes.last == .some(nil))
    }

    @Test func aCloudTabThatCannotReachItsMachineSaysWhy() async throws {
        let path = "/home/cmux/notes.md"
        let machine = MachineFiles()
        machine.set(path, "one\n")
        machine.offline = true
        let provider = FilePageProvider(kind: .editor, file: URL(fileURLWithPath: path), host: Host(), libraries: nil, images: NoImages(),
                                        files: RemoteFilePageFiles(client: machine, machine: Self.machine))
        do {
            _ = try await Self.call(provider, "config")
            Issue.record("an offline machine's file opened")
        } catch let error as PageError {
            #expect(error.code == "cmux.editor.unavailable")
            #expect(error.message.contains(Self.machine))
            #expect(error.retryable)
        }
        // A machine whose daemon serves no files says that instead.
        machine.offline = false
        machine.served = false
        do {
            _ = try await Self.call(provider, "config")
            Issue.record("a machine without fs-v1 opened a file")
        } catch let error as PageError {
            #expect(error.code == "cmux.editor.unavailable")
            #expect(error.message == FilePageStrings.remoteNoFiles(Self.machine))
        }
        provider.close()
    }

    @Test func aFileOpenedThroughASymlinkSavesAtItsTargetsRevision() async throws {
        let link = "/home/cmux/AGENTS.md", target = "/home/cmux/CLAUDE.md"
        let machine = MachineFiles()
        machine.set(target, "one\n")
        machine.links[link] = target
        let provider = FilePageProvider(kind: .markdown, file: URL(fileURLWithPath: link), host: Host(), libraries: nil, images: NoImages(),
                                        files: RemoteFilePageFiles(client: machine, machine: Self.machine))
        let config = try await Self.call(provider, "config")
        #expect(config["text"]?.stringValue == "one\n")
        let base = try #require(config["hash"]?.stringValue)
        // The link's own revision never matches the write's check of its target: the save asks first.
        let saved = try await Self.call(provider, "save", ["path": .string(link), "text": "two\n", "baseHash": .string(base)])
        #expect(machine.files[target]?.text == "two\n")
        #expect(machine.writes.map(\.1) == ["two\n"])
        // Written on the VM since: a conflict with the VM's text, nothing replaced.
        machine.set(target, "three\n")
        do {
            _ = try await Self.call(provider, "save", ["path": .string(link), "text": "mine\n", "baseHash": saved["hash"] ?? .null])
            Issue.record("a stale save replaced the symlinked file")
        } catch let error as PageError {
            #expect(error.code == "cmux.markdown.conflict")
            #expect(error.details?["text"]?.stringValue == "three\n")
        }
        #expect(machine.files[target]?.text == "three\n")
        #expect(machine.writes.count == 1)
        provider.close()
    }

    @Test func aCloudTabFollowsWritesBehindASymlink() async throws {
        let link = "/home/cmux/AGENTS.md", target = "/home/cmux/CLAUDE.md"
        let machine = MachineFiles()
        machine.set(target, "one\n")
        machine.links[link] = target
        let files = RemoteFilePageFiles(client: machine, machine: Self.machine)
        var changes: [FileSnapshot?] = []
        let watch = try #require(files.watch(URL(fileURLWithPath: link), inWorkspace: { true }, clock: ContinuousClock(),
                                             onChange: { changes.append($0) }, onUnavailable: { _ in }) as? RemoteFileChangeWatch)
        watch.knownHash = FileDocument.hash(Data("one\n".utf8))
        await watch.check()
        #expect(changes.isEmpty)
        // An agent edits the target; the link's revision stays the same.
        machine.set(target, "two\n")
        await watch.check()
        #expect(changes.compactMap { $0?.text } == ["two\n"])
    }

    @Test func aFileThatKeepsChangingWhileReadNeverSavesOverTheNewText() async throws {
        let path = "/home/cmux/build.log"
        let machine = MachineFiles()
        machine.set(path, "one\n")
        let provider = FilePageProvider(kind: .editor, file: URL(fileURLWithPath: path), host: Host(), libraries: nil, images: NoImages(),
                                        files: RemoteFilePageFiles(client: machine, machine: Self.machine))
        let config = try await Self.call(provider, "config")
        let base = try #require(config["hash"]?.stringValue)
        // Every read races a write on the VM and still returns the page's bytes: no revision read
        // alongside them is theirs, so the save is a conflict and the VM's text stays.
        machine.staleRead = "one\n"
        do {
            _ = try await Self.call(provider, "save", ["path": .string(path), "text": "mine\n", "baseHash": .string(base)])
            Issue.record("a save replaced text written during its read")
        } catch let error as PageError {
            #expect(error.code == "cmux.editor.conflict")
            #expect(error.details?["deleted"] == nil)
        }
        #expect(machine.writes.isEmpty)
        #expect(machine.files[path]?.text.hasPrefix("one\n+") == true)
        provider.close()
    }

    @Test func aFileTooLargeToWriteSaysSoInThePagesWords() async throws {
        let path = "/home/cmux/notes.md"
        let machine = MachineFiles()
        machine.set(path, "one\n")
        machine.writeCap = 3
        let files = RemoteFilePageFiles(client: machine, machine: Self.machine)
        let snapshot = try await files.read(URL(fileURLWithPath: path), inWorkspace: true)
        do {
            _ = try await files.save("longer\n", to: URL(fileURLWithPath: path), baseHash: snapshot.hash, inWorkspace: true)
            Issue.record("a write over the cap saved")
        } catch {
            #expect(error == .failed(FilePageStrings.remoteTooLargeToSave(Self.machine)))
        }
    }

    @Test func aCloudTerminalsPathNamesTheMachinesFile() {
        #expect(TerminalLinkResolver.remoteCandidates("/home/cmux/app/README.md:12", cwd: "/tmp") == ["/home/cmux/app/README.md"])
        #expect(TerminalLinkResolver.remoteCandidates("“src/main.rs:3:5”,", cwd: "/home/cmux/app") == ["/home/cmux/app/src/main.rs"])
        #expect(TerminalLinkResolver.remoteCandidates("../notes.md", cwd: "file://vm/home/cmux/app") == ["/home/cmux/notes.md"])
        // A URL keeps its own route; `~` is that machine's home, unknown here; no folder, no path.
        #expect(TerminalLinkResolver.remoteCandidates("https://example.com/a.md", cwd: "/home/cmux").isEmpty)
        #expect(TerminalLinkResolver.remoteCandidates("~/notes.md", cwd: "/home/cmux").isEmpty)
        #expect(TerminalLinkResolver.remoteCandidates("notes.md", cwd: nil).isEmpty)
    }
}
