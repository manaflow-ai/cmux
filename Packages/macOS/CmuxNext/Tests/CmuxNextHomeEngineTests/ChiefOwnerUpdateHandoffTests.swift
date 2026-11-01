import CmuxNextDaemon
@testable import CmuxNextHomeEngine
import Foundation
import Testing

/// Leo, 2026-10-29: "JUST FUCKING REMOVE THE FUCKING OLD DAMEMONS". The Chief's cmux-tui owner
/// outlived every update: it was never handed off, so it ran the old build forever. It is handed
/// off now once an update replaced the binary it runs from (from the owner's own `cli_path` and
/// `build_commit`), and still never for being another install that exists (two builds sharing
/// NIGHTLY's Chief home would restart each other's owner).
struct ChiefOwnerUpdateHandoffTests {
    static let bundled = "/Applications/cmux NIGHTLY.app/Contents/Resources/bin/cmux-tui"
    static let other = "/Applications/cmux NEXT.app/Contents/Resources/bin/cmux-tui"

    static func decide(bundledBinary: Bool = true, ownerPath: String?, ownerCommit: String? = "aaaaaaa",
                       bundledCommit: String? = "bbbbbbb", exists: Set<String> = [bundled, other]) async -> Bool {
        await ChiefConversationOwner.handsOffForUpdate(binaryIsBundled: bundledBinary, ownerPath: ownerPath,
                                                       ownerCommit: ownerCommit, bundledPath: bundled,
                                                       bundledCommit: { bundledCommit },
                                                       fileExists: { exists.contains($0) })
    }

    @Test func anUpdateThatWroteThisBuildOverTheOwnersBinaryHandsItOff() async {
        #expect(await Self.decide(ownerPath: Self.bundled))
    }

    @Test func anOwnerWhoseBinaryIsGoneIsHandedOff() async {
        #expect(await Self.decide(ownerPath: Self.other, exists: [Self.bundled]))
    }

    @Test func anotherInstallThatStillExistsIsKept() async {
        #expect(!(await Self.decide(ownerPath: Self.other)))
    }

    @Test func theSameBuildOrAnUnknownBuildIsKept() async {
        #expect(!(await Self.decide(ownerPath: Self.bundled, ownerCommit: "bbbbbbb")))
        #expect(!(await Self.decide(ownerPath: Self.bundled, ownerCommit: nil)))
        #expect(!(await Self.decide(ownerPath: Self.bundled, bundledCommit: nil)))
    }

    @Test func anOwnerThatDoesNotSayItsPathOrAnExternalBinaryNeverHandsOff() async {
        #expect(!(await Self.decide(ownerPath: nil)))
        // `CMUX_NEXT_TUI_BIN`: the next ensure would start that same binary again.
        #expect(!(await Self.decide(bundledBinary: false, ownerPath: Self.bundled)))
    }

    @Test func identifyCarriesTheOwnersBinaryPath() throws {
        let json = #"{"app":"cmux-tui","protocol":12,"generation":"g1","cli_path":"/A/cmux-tui","build_commit":"aaaaaaa"}"#
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
        #expect(identity.cliPath == "/A/cmux-tui")
        let relative = #"{"app":"cmux-tui","protocol":12,"generation":"g1","cli_path":"cmux-tui"}"#
        #expect(try JSONDecoder().decode(DaemonIdentity.self, from: Data(relative.utf8)).cliPath == nil)
    }
}
