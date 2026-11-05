@testable import CmuxNextApp
import CmuxNextCloud
import CmuxNextDesign
import Testing

/// A Cloud chat start whose git seed is refused asks the person before it copies the folder,
/// instead of copying it silently (a 12.8 GB copy of cmuxterm-hq ran a 16 GB machine's disk out
/// and ended in "Broken pipe"). The refusal's words are cmux-tui's (`link seed push --seed-only`,
/// tested in `tests/link_seed.rs`); the App asks first and copies only on the person's yes.
/// RED before the ask: the start passed no `--on-seed-refusal`, and no answer read as a refusal.
@Suite
@MainActor
struct CloudSeedRefusalTests {
    @Test func theFirstCopyAsksAndOnlyTheConfirmedOneCopies() {
        let ask = CloudMoveCLI.startChatCopyArguments(key: "k", account: "a/", machine: "vm", socket: "/s", local: "/l", subpath: "",
                                                     workRoots: ["/home/cmux/work"], acpmuxHome: nil, store: false, onSeedRefusal: .ask)
        #expect(ask.suffix(2) == ["--on-seed-refusal", "ask"])
        let copy = CloudMoveCLI.startChatCopyArguments(key: "k", account: "a/", machine: "vm", socket: "/s", local: "/l", subpath: "",
                                                      workRoots: ["/home/cmux/work"], acpmuxHome: nil, store: true, onSeedRefusal: .copy)
        #expect(copy.suffix(4) == ["--store", "default", "--on-seed-refusal", "copy"])
    }

    @Test func aRefusedSeedAsksWithItsReasonAndAnyOtherAnswerDoesNot() throws {
        let why = "The machine can't clone this folder: submodule subrouter has uncommitted changes; copying the folder instead would send 36,796 files (12.8 GB)"
        let refused = try #require(CloudSeedRefusal(CloudMoveCLI.Answer(ok: false, errorCode: "seed_refused", error: why), machine: "cloud-chats-2"))
        #expect(refused.message == why)
        let spec = refused.spec
        #expect(spec.lines == [why])
        #expect(spec.buttons.map(\.id) == ["cancel", CloudSeedRefusal.copyButton])
        #expect(spec.buttons.last?.role == .default)
        #expect(spec.title.contains("cloud-chats-2"))

        #expect(CloudSeedRefusal(CloudMoveCLI.Answer(ok: false, errorCode: "disk_full", error: "full"), machine: "m") == nil)
        #expect(CloudSeedRefusal(CloudMoveCLI.Answer(ok: true), machine: "m") == nil)
    }
}
