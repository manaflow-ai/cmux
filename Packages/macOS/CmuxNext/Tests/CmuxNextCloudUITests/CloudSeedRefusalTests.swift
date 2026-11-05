import CmuxNextCloud
import CmuxNextCloudUI
import CmuxNextDesign
import Testing
import Foundation

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

    private struct Declined: Error, Equatable { let reason: String }

    @Test func aSeedThatIsNotRefusedCopiesOnceAndAskingNowhereCopiesNothing() async throws {
        var asked: [CloudMoveCLI.SeedRefusal] = []
        let seeded = try await CloudSeedRefusal.copying(machine: "m", in: { nil }, declined: { Declined(reason: $0) }) { refusal in
            asked.append(refusal)
            return (CloudMoveCLI.Answer(ok: true), "seeded")
        }
        #expect(seeded.1 == "seeded")
        #expect(asked == [.ask])

        asked = []
        await #expect(throws: Declined(reason: "why")) {
            _ = try await CloudSeedRefusal.copying(machine: "m", in: { nil }, declined: { Declined(reason: $0) }) { refusal in
                asked.append(refusal)
                return (CloudMoveCLI.Answer(ok: false, errorCode: "seed_refused", error: "why"), "")
            }
        }
        #expect(asked == [.ask], "a refusal with no window to ask in copied")
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
        #expect(CloudSeedRefusal(answer, machine: "vm")?.fallbackCode == "not_git")
    }

    /// A private repository the machine can't read without the cmux GitHub App: the dialog offers
    /// Connect GitHub, which opens the App's install page and ends the start with its reason (so
    /// Retry seeds again once it is installed), and nothing is copied.
    @Test func aPrivateRepoOffersConnectGitHubWhichOpensTheInstallPageAndCopiesNothing() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-seed-github-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let binary = dir.appendingPathComponent("cmux")
        let install = "https://github.com/apps/cmux/installations/new"
        let line = #"{"ok":false,"error_code":"seed_refused","error":"needs the cmux GitHub App","fallback_code":"seed.needs_github","install_url":"\#(install)"}"#
        try "#!/bin/sh\necho '\(line)'\nexit 1\n".write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let cli = CloudMoveCLI(binary: binary, timeout: .seconds(20))

        var asked: [CloudMoveCLI.SeedRefusal] = []
        var opened: [URL] = []
        var buttons: [String] = []
        await #expect(throws: Declined(reason: "needs the cmux GitHub App")) {
            _ = try await CloudSeedRefusal.copying(machine: "vm", ask: { refused in
                buttons = refused.spec.buttons.map(\.id)
                return .connectGitHub
            }, open: { opened.append($0) }, declined: { Declined(reason: $0) }) { refusal in
                asked.append(refusal)
                return try await cli.startChatCopy(key: "k", account: "a/", machine: "vm", socket: "/s", local: "/l", subpath: "",
                                                   workRoots: ["/w"], acpmuxHome: nil, onSeedRefusal: refusal)
            }
        }
        #expect(buttons == ["cancel", CloudSeedRefusal.copyButton, CloudSeedRefusal.connectGitHubButton])
        #expect(opened == [try #require(URL(string: install))])
        #expect(asked == [.ask], "Connect GitHub copied the folder")

        let notGit = try #require(CloudSeedRefusal(CloudMoveCLI.Answer(ok: false, errorCode: "seed_refused", error: "why", fallbackCode: "not_git"), machine: "vm"))
        #expect(notGit.spec.buttons.map(\.id) == ["cancel", CloudSeedRefusal.copyButton], "only a private repo offers Connect GitHub")
    }
}

