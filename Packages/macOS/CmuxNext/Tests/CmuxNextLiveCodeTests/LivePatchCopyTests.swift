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

    @Test func aFileThatIsNotSignedCodeIsRefusedEvenByAnAppWithNoTeam() throws {
        let live = try folder()
        let path = live.url.appendingPathComponent("plain.dylib")
        try Data("plain bytes".utf8).write(to: path)
        #expect(throws: LiveCodeError.self) { try PatchSignature.check(path.path, app: .noTeam) }
        #expect(throws: LiveCodeError.self) { try PatchSignature.check(path.path, app: .team("ABCDE12345")) }
    }
}

/// Whose patches an app loads (cmux#13742): a team-signed app only its team's, an app with no team any
/// validly signed one.
struct PatchSignatureTests {
    /// An ad hoc signed Mach-O: a copy of this test binary, which the linker signed ad hoc.
    private func adHocPatch() throws -> URL {
        var info = Dl_info()
        #expect(dladdr(#dsohandle, &info) != 0)
        let image = URL(fileURLWithPath: String(cString: info.dli_fname))
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("adhoc-\(UUID().uuidString).dylib")
        try FileManager.default.copyItem(at: image, to: copy)
        return copy
    }

    @Test func anAppWithNoTeamLoadsAnAdHocPatch() throws {
        let patch = try adHocPatch()
        defer { try? FileManager.default.removeItem(at: patch) }
        try PatchSignature.check(patch.path, app: .noTeam)
    }

    @Test func aTeamSignedAppRefusesAnAdHocPatch() throws {
        let patch = try adHocPatch()
        defer { try? FileManager.default.removeItem(at: patch) }
        #expect(throws: LiveCodeError.self) { try PatchSignature.check(patch.path, app: .team("ABCDE12345")) }
    }

    @Test func aTeamSignedAppRefusesAnotherTeamsCode() throws {
        // Validly signed, by Apple: not team ABCDE12345.
        try PatchSignature.check("/usr/bin/true", app: .noTeam)
        #expect(throws: LiveCodeError.self) { try PatchSignature.check("/usr/bin/true", app: .team("ABCDE12345")) }
    }

    @Test func anAppWhoseSignatureIsUnreadableOrMalformedRefusesEverything() throws {
        let patch = try adHocPatch()
        defer { try? FileManager.default.removeItem(at: patch) }
        #expect(throws: LiveCodeError.self) { try PatchSignature.check(patch.path, app: .unreadable("test")) }
        #expect(throws: LiveCodeError.self) { try PatchSignature.check("/usr/bin/true", app: .team("ABC\" or 1")) }
    }

    /// A team's app counts as one only while the kernel enforces library validation: otherwise a file
    /// swapped in between the check and dlopen would load.
    @Test func aTeamSignedAppCountsOnlyWithLibraryValidation() throws {
        let runtime = PatchSignature.hardenedRuntime
        #expect(PatchSignature.signer(team: "ABCDE12345", status: runtime, entitlements: [:]) == .team("ABCDE12345"))
        #expect(PatchSignature.signer(team: "ABCDE12345", status: PatchSignature.requireLibraryValidation, entitlements: [:]) == .team("ABCDE12345"))
        let off = ["com.apple.security.cs.disable-library-validation": true]
        guard case .unprotected = PatchSignature.signer(team: "ABCDE12345", status: runtime, entitlements: off) else {
            Issue.record("the disable-library-validation entitlement still counted as protected")
            return
        }
        guard case .unprotected = PatchSignature.signer(team: "ABCDE12345", status: 0, entitlements: [:]),
              case .unprotected = PatchSignature.signer(team: "ABCDE12345", status: nil, entitlements: [:]) else {
            Issue.record("no hardened runtime, or no readable status, still counted as protected")
            return
        }
        #expect(PatchSignature.signer(team: nil, status: 0, entitlements: off) == .noTeam)
        #expect(PatchSignature.signer(team: "", status: runtime, entitlements: [:]) == .noTeam)
    }

    @Test func anUnprotectedTeamAppRefusesEvenItsOwnTeamsCode() throws {
        #expect(throws: LiveCodeError.self) {
            try PatchSignature.check("/usr/bin/true", app: .unprotected(team: "ABCDE12345", why: "test"))
        }
    }
}
