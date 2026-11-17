import CmuxNextCloud
import CmuxNextCloudUI
import CmuxNextDesign
import Testing
import Foundation

/// A Cloud chat start whose git seed is refused copies the folder by itself and never asks (2026-11-10:
/// "instead of this dialog, let's just automatically do it"; 2026-11-13: "instead of asking user to copy the
/// folder, just do it automatically so that it just works": a start that asked sat on a dialog while its chat
/// said "Thinking"). Only a copy the machine's disk cannot hold is not made: a silent 12.8 GB copy of
/// cmuxterm-hq ran a 16 GB machine's disk out and ended in "Broken pipe".
/// The refusal's words are cmux-tui's (`link seed push --seed-only`, tested in `tests/link_seed.rs`).
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

    @Test func onlyASeedRefusalIsOneAndItKeepsCmuxTuisReason() throws {
        let why = "The machine can't clone this folder: submodule subrouter has uncommitted changes; copying the folder instead would send 36,796 files (12.8 GB)"
        let refused = try #require(CloudSeedRefusal(CloudMoveCLI.Answer(ok: false, errorCode: "seed_refused", error: why), machine: "cloud-chats-2"))
        #expect(refused.message == why)
        #expect(CloudSeedRefusal(CloudMoveCLI.Answer(ok: false, errorCode: "disk_full", error: "full"), machine: "m") == nil)
        #expect(CloudSeedRefusal(CloudMoveCLI.Answer(ok: true), machine: "m") == nil)
    }

    /// A machine's room is its disk less what its image and work keep: 4 GiB on the old 16 GB disk, 52 GiB on a
    /// 64 GB one; a machine whose size is not known is taken for the smallest.
    @Test func aMachinesRoomFollowsItsDisk() {
        let gib: Int64 = 1_073_741_824
        #expect(CloudSeedRefusal.room(diskMb: 16_384) == 4 * gib)
        #expect(CloudSeedRefusal.room(diskMb: 65_536) == 52 * gib)
        #expect(CloudSeedRefusal.room(diskMb: nil) == CloudSeedRefusal.room(diskMb: 16_384))
        #expect(CloudSeedRefusal.room(diskMb: 1_024) == CloudSeedRefusal.leastRoomBytes)
    }

    private struct Declined: Error, Equatable { let reason: String }

    @Test func aSeedThatIsNotRefusedCopiesOnce() async throws {
        var asked: [CloudMoveCLI.SeedRefusal] = []
        let seeded = try await CloudSeedRefusal.copying(machine: "m", diskMb: nil, declined: { Declined(reason: $0) }) { refusal in
            asked.append(refusal)
            return (CloudMoveCLI.Answer(ok: true), "seeded")
        }
        #expect(seeded.1 == "seeded")
        #expect(asked == [.ask])
    }

    /// The person's folder is copied with no question, whatever its size, when the machine's disk holds it:
    /// 1.9 GB on a 16 GB disk, the 23.2 GB checkout on a 64 GB one, and a folder whose size could not be read.
    @Test func aRefusedSeedCopiesTheFolderWithoutAsking() async throws {
        for (bytes, disk): (Int64?, Int?) in [(1_900_000_000, 16_384), (23_200_000_000, 65_536), (nil, nil)] {
            var asked: [CloudMoveCLI.SeedRefusal] = []
            let copied = try await CloudSeedRefusal.copying(machine: "m", diskMb: disk, declined: { Declined(reason: $0) }) { refusal in
                asked.append(refusal)
                return refusal == .ask
                    ? (CloudMoveCLI.Answer(ok: false, errorCode: "seed_refused", error: "why", fallbackCode: "no_base", copyBytes: bytes), "")
                    : (CloudMoveCLI.Answer(ok: true), "copied")
            }
            #expect(copied.1 == "copied")
            #expect(asked == [.ask, .copy])
        }
    }

    /// A copy the machine's disk cannot hold is not made, and the start ends with words that name the folder's
    /// size and the machine instead of waiting on a question.
    @Test func aCopyTheDiskCannotHoldIsNotMadeAndSaysSo() async throws {
        var asked: [CloudMoveCLI.SeedRefusal] = []
        var reason = ""
        do {
            _ = try await CloudSeedRefusal.copying(machine: "cloud-chats", diskMb: 16_384, declined: { Declined(reason: $0) }) { refusal in
                asked.append(refusal)
                return (CloudMoveCLI.Answer(ok: false, errorCode: "seed_refused", error: "why", fallbackCode: "seed.needs_github", copyBytes: 23_200_000_000), "")
            }
            Issue.record("a 23.2 GB copy to a 16 GB disk was made")
        } catch let declined as Declined { reason = declined.reason }
        #expect(asked == [.ask], "a 23.2 GB copy to a 16 GB disk was made")
        #expect(reason.contains("cloud-chats") && reason.contains("23"))
        #expect(reason != "why", "the start ended with cmux-tui's clone reason, not that the folder does not fit")
    }

    /// The refusal names the seed plan's code (`not_git`, `submodule_local_work`, ...) so the log says why.
    @Test func aRefusedSeedCarriesThePlansFallbackCodeFromTheCLIAnswer() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-seed-refusal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let binary = dir.appendingPathComponent("cmux")
        let line = #"{"ok":false,"error_code":"seed_refused","error":"why","fallback_code":"not_git","copy_files":2,"copy_bytes":5}"#
        try "#!/bin/sh\necho '\(line)'\nexit 1\n".write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let (answer, _) = try await CloudMoveCLI(binary: binary, timeout: .seconds(20))
            .startChatCopy(key: "k", account: "a/", machine: "vm", socket: "/s", local: "/l", subpath: "", workRoots: ["/w"], acpmuxHome: nil, onSeedRefusal: .ask)
        #expect(answer.fallbackCode == "not_git")
        #expect(answer.copyBytes == 5)
        #expect(CloudSeedRefusal(answer, machine: "vm")?.fallbackCode == "not_git")
    }
}
