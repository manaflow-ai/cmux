@testable import CmuxNextAgentPane
import CmuxNextCompat
import Darwin
import Foundation
import Testing

/// The AgentPane sites p10-stability-075 moved behind checked reads or a safe API: the duplicate-key check
/// reads every byte through a bounds-checked load, the stored-name read parses getattrlist's reply from the
/// array instead of a raw pointer, the person key writes its line from its own zeroed buffer, and the shells
/// spawn through one C-string list helper.
@Suite struct AgentPaneMemorySafetyTests {
    // MARK: AcpmuxJSONKeys (checked byte reads)

    @Test func theKeyCheckJudgesFramesOfEveryLengthWithoutReadingPastThem() {
        // Lengths around the 8-byte word path: the last word of a value string can end inside the frame.
        for padding in 0..<20 {
            let value = String(repeating: "a", count: padding)
            #expect(AcpmuxJSONKeys.verdict(#"{"k":"\#(value)"}"#) == .clean, "padding \(padding)")
            #expect(AcpmuxJSONKeys.verdict(#"{"k":"\#(value)""#) == .malformed, "unclosed object, padding \(padding)")
            #expect(AcpmuxJSONKeys.verdict(#"{"k":"\#(value)"#) == .malformed, "unclosed string, padding \(padding)")
        }
        #expect(AcpmuxJSONKeys.verdict(#"{"k":1,"k":2}"#) == .duplicate)
        #expect(AcpmuxJSONKeys.verdict("{\"caf\u{E9}\":1,\"cafe\u{301}\":2}") == .duplicate, "canonically equal keys")
        #expect(AcpmuxJSONKeys.verdict(#"{"a":"é😀","b":[true,false,null,-1.5e3]}"#) == .clean)
        #expect(AcpmuxJSONKeys.verdict(#"{"a":"\u12"}"#) == .malformed, "a short \\u escape at the end")
        #expect(AcpmuxJSONKeys.verdict(#"{"a":tru"#) == .malformed, "a literal cut at the end")
        #expect(AcpmuxJSONKeys.verdict("") == .malformed)
        #expect(AcpmuxJSONKeys.refuses([0x7B, 0x22, 0xE2, 0x82]), "a UTF-8 sequence cut at the end")
        #expect(!AcpmuxJSONKeys.refuses(Array(#"{"x":"€"}"#.utf8)))
    }

    // MARK: AcpmuxPathPolicy (getattrlist reply parsed from the array)

    @Test func theStoredNameIsTheFilesystemsSpellingOfTheLastComponent() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "cmux-075-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "MixedCase.txt")
        try Data("x".utf8).write(to: file)
        #expect(AcpmuxPathPolicy.storedName(file.path) == "MixedCase.txt")
        #expect(AcpmuxPathPolicy.storedName(folder.path + "/missing-\(UUID().uuidString)") == nil)
        let canonical = try #require(AcpmuxPathPolicy.canonical(folder.path))
        #expect(AcpmuxPathPolicy.isDirectory(canonical))
        #expect(!AcpmuxPathPolicy.isDirectory(canonical + "/MixedCase.txt"))
    }

    // MARK: Folder and file checks without an ObjCBool pointer

    @Test func folderAndFileChecksFollowLinksAndRefuseTheOtherKind() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "cmux-075-\(UUID().uuidString)", directoryHint: .isDirectory)
        let sessions = home.appending(path: "sessions", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sessions.appending(path: "kept"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try Data("x".utf8).write(to: sessions.appending(path: "plain"))
        try FileManager.default.createSymbolicLink(at: sessions.appending(path: "linked"), withDestinationURL: sessions.appending(path: "kept"))
        #expect(AcpmuxChiefSessionRouter.keeps(session: "kept", home: home))
        #expect(AcpmuxChiefSessionRouter.keeps(session: "linked", home: home), "a link to a folder counts, as fileExists did")
        #expect(!AcpmuxChiefSessionRouter.keeps(session: "plain", home: home))
        #expect(!AcpmuxChiefSessionRouter.keeps(session: "missing", home: home))

        let file = sessions.appending(path: "plain")
        #expect(AgentPaneFileOpen.resolve(file.path)?.lastPathComponent == "plain")
        #expect(AgentPaneFileOpen.resolve(sessions.path) == nil, "a folder is not a file")
        #expect(AgentPaneFileOpen.resolve(sessions.path + "/missing") == nil)
    }

    // MARK: AcpmuxSecretKey (its own buffer, zeroed)

    @Test func theKeyLineIsSixtyFourHexDigitsAndANewline() throws {
        let key = try #require(AcpmuxSecretKey())
        var ends: [Int32] = [-1, -1]
        // SAFETY: pipe writes its two descriptors into the array's own storage (two Int32), lent for the call.
        try #require(unsafe pipe(&ends) == 0)
        defer { close(ends[0]) }
        #expect(key.writeLine(to: ends[1]))
        close(ends[1])
        let line = FileHandle(fileDescriptor: ends[0], closeOnDealloc: false).readDataToEndOfFile()
        #expect(line.count == AcpmuxSecretKey.lineLength)
        #expect(line.last == 0x0A)
        #expect(line.dropLast().allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) })

        // The proof is the same HMAC each time and differs per nonce.
        let first = key.holdsProof(instance: "i", nonce: "n1")
        #expect(first.count == 64 && first == key.holdsProof(instance: "i", nonce: "n1"))
        #expect(first != key.holdsProof(instance: "i", nonce: "n2"))
        #expect(key.holds(proof: first, instance: "i", nonce: "n1"))
        #expect(AcpmuxSecretKey.newNonce()?.count == 64)
    }

    // MARK: Process facts (sysctl, proc_pidpath)

    @Test func thisProcessIsRunningAndHasAnExecutablePath() throws {
        #expect(agentPaneProcessIsRunning(getpid()))
        #expect(!agentPaneProcessIsRunning(0))
        let path = try #require(AcpmuxVersionHandoff.executablePath(pid: getpid()))
        #expect(path.hasPrefix("/"))
        #expect(FileManager.default.fileExists(atPath: path))
    }

    // MARK: AgentPaneProjectCopy (write from the array)

    @Test func anAppendAddsTheMissingNewlineFirst() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "cmux-075-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: ".gitignore")
        try Data("one".utf8).write(to: file)
        #expect(AgentPaneProjectCopy.append(["two", "three"], to: file.path))
        #expect(try String(contentsOf: file, encoding: .utf8) == "one\ntwo\nthree\n")
    }
}
