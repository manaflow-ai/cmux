import Foundation
import Testing
@testable import CmuxNextLiveCode

/// The signature check and dlopen read one private copy of a patch (cmux#36330 review: the NIGHTLY
/// turns off library validation, so a check of the shared folder's file could be swapped before
/// the load).
struct LivePatchCopyTests {
    private func folder() throws -> LiveFolder {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("live-code-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return LiveFolder(url: url)
    }

    @Test func theCopyHasThePatchBytesInAFolderOnlyThisUserCanEnter() throws {
        let live = try folder()
        let bytes = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try bytes.write(to: live.url.appendingPathComponent("patch-1.dylib"))
        let copy = try live.privateCopy("patch-1.dylib")
        defer { try? FileManager.default.removeItem(at: copy) }
        #expect(try Data(contentsOf: copy) == bytes)
        #expect(copy.deletingLastPathComponent() != live.url)
        var info = stat()
        #expect(lstat(copy.deletingLastPathComponent().path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o700 && info.st_uid == getuid())
        // Each load gets its own copy.
        let again = try live.privateCopy("patch-1.dylib")
        defer { try? FileManager.default.removeItem(at: again) }
        #expect(again != copy)
    }

    @Test func aLinkInTheFolderIsRefusedNotFollowed() throws {
        let live = try folder()
        let elsewhere = live.url.appendingPathComponent("elsewhere.bin")
        try Data("not a patch".utf8).write(to: elsewhere)
        try FileManager.default.createSymbolicLink(at: live.url.appendingPathComponent("patch-2.dylib"), withDestinationURL: elsewhere)
        #expect(throws: LiveCodeError.self) { try live.privateCopy("patch-2.dylib") }
    }

    @Test func aFolderIsNotAPatch() throws {
        let live = try folder()
        try FileManager.default.createDirectory(at: live.url.appendingPathComponent("patch-3.dylib"), withIntermediateDirectories: false)
        #expect(throws: LiveCodeError.self) { try live.privateCopy("patch-3.dylib") }
    }

    @Test func aFileThatIsNotSignedCodeIsNotOurTeams() throws {
        let live = try folder()
        let path = live.url.appendingPathComponent("plain.dylib")
        try Data("plain bytes".utf8).write(to: path)
        #expect(throws: LiveCodeError.self) { try PatchSignature.check(path.path) }
    }
}
