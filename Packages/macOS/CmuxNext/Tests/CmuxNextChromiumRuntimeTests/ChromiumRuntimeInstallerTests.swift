import Foundation
import Testing
@testable import CmuxNextChromiumRuntime

/// Download, verify and install of a pinned Chromium runtime pack, with real
/// `tar` and small packs (plans/cmux-next/bundle-size-DESIGN.md section 6.3).
struct ChromiumRuntimeInstallerTests {
    let folder: TemporaryFolder
    let store: ChromiumRuntimeStore

    init() throws {
        folder = try TemporaryFolder()
        store = ChromiumRuntimeStore(root: folder.url.appending(path: "ChromiumRuntime"))
    }

    func installer(_ pin: ChromiumRuntimePin, downloader: any ChromiumRuntimeDownloading,
                   unpacker: any ChromiumRuntimeUnpacking = TarChromiumRuntimeUnpacker(),
                   signatures: any ChromiumRuntimeSignatureChecking = RecordingSignatures(),
                   network: FixedNetwork = FixedNetwork(), maxAttempts: Int? = 1) -> ChromiumRuntimeInstaller {
        ChromiumRuntimeInstaller(pin: pin, store: store, downloader: downloader, unpacker: unpacker, signatures: signatures,
                                 network: network, retryDelays: [.zero], maxAttempts: maxAttempts)
    }

    @Test func installsAGoodPack() async throws {
        let (data, pin) = try PackFixture.make(in: folder.url)
        let state = await installer(pin, downloader: MemoryDownloader(bytes: data)).run(.user)
        guard case .installed(let installation) = state else {
            Issue.record("expected installed, got \(state)")
            return
        }
        #expect(installation.pin == pin)
        let frameworks = installation.frameworksDirectory
        #expect(FileManager.default.fileExists(atPath: frameworks.appending(path: "Chromium Embedded Framework.framework/Versions/Current").path))
        #expect(FileManager.default.fileExists(atPath: frameworks.appending(path: "cmux TEST Helper.app").path))
        #expect(store.select(for: pin) == .exact(installation))
        #expect(!FileManager.default.fileExists(atPath: store.partialFile(for: pin).path))
        let names = try FileManager.default.contentsOfDirectory(atPath: store.root.path)
        #expect(!names.contains { $0.hasPrefix(".staging-") })
    }

    @Test func anInstalledPackIsNotDownloadedAgain() async throws {
        let (data, pin) = try PackFixture.make(in: folder.url)
        _ = await installer(pin, downloader: MemoryDownloader(bytes: data)).run(.user)
        let second = MemoryDownloader(bytes: data)
        let state = await installer(pin, downloader: second).run(.user)
        #expect(state.name == "installed")
        #expect(await second.calls == 0)
    }

    @Test func aWrongHashIsRefusedAndTheFileDropped() async throws {
        let (data, pin) = try PackFixture.make(in: folder.url)
        var tampered = data
        tampered[tampered.count / 2] ^= 0xFF
        let state = await installer(pin, downloader: MemoryDownloader(bytes: tampered)).run(.user)
        #expect(state == .failed(.checksumMismatch, attempt: 1))
        #expect(!FileManager.default.fileExists(atPath: store.partialFile(for: pin).path))
        #expect(store.installation(key: pin.key) == nil)
    }

    @Test func aPartialDownloadResumesWhereItStopped() async throws {
        let (data, pin) = try PackFixture.make(in: folder.url)
        let partial = store.partialFile(for: pin)
        try FileManager.default.createDirectory(at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.prefix(data.count / 2).write(to: partial)
        let downloader = MemoryDownloader(bytes: data)
        let state = await installer(pin, downloader: downloader).run(.user)
        #expect(state.name == "installed")
        #expect(await downloader.offsets == [Int64(data.count / 2)])
    }

    @Test func aFailedTransferIsRetried() async throws {
        let (data, pin) = try PackFixture.make(in: folder.url)
        let downloader = MemoryDownloader(bytes: data, failFirst: 1)
        let installer = installer(pin, downloader: downloader, maxAttempts: 3)
        let states = await installer.states()
        let state = await installer.run(.user)
        #expect(state.name == "installed")
        #expect(await downloader.calls == 2)
        var seen: [ChromiumRuntimeInstallState] = []
        for await next in states {
            seen.append(next)
            if next.name == "installed" { break }
        }
        #expect(seen.contains(.failed(.transfer("connection reset"), attempt: 1)))
    }

    @Test func aPackWithoutTheBaseHelperIsRefused() async throws {
        let (data, pin) = try PackFixture.make(in: folder.url, shape: .missingHelper)
        let state = await installer(pin, downloader: MemoryDownloader(bytes: data)).run(.user)
        #expect(state == .failed(.missing("Helper.app"), attempt: 1))
        #expect(store.installations().isEmpty)
        let names = try FileManager.default.contentsOfDirectory(atPath: store.root.path)
        #expect(!names.contains { $0.hasPrefix(".staging-") })
    }

    @Test func aSymlinkLeavingThePackIsRefused() async throws {
        let (data, pin) = try PackFixture.make(in: folder.url, shape: .symlinkOutside)
        let state = await installer(pin, downloader: MemoryDownloader(bytes: data)).run(.user)
        guard case .failed(.unsafeEntry(let entry), _) = state else {
            Issue.record("expected unsafeEntry, got \(state)")
            return
        }
        #expect(entry.hasSuffix("escape"))
        #expect(store.installations().isEmpty)
    }

    @Test(arguments: [
        "/etc/passwd",
        "cmux TEST Chromium/../../evil",
        "other/x",
    ])
    func anUnsafeArchiveEntryIsRefusedBeforeUnpacking(entry: String) async throws {
        let (data, pin) = try PackFixture.make(in: folder.url)
        let unpacker = FixedEntriesUnpacker(names: ["cmux TEST Chromium/", entry])
        let state = await installer(pin, downloader: MemoryDownloader(bytes: data), unpacker: unpacker).run(.user)
        #expect(state == .failed(.unsafeEntry(entry), attempt: 1))
    }

    @Test func aReleasePackChecksEverySignatureAgainstItsTeam() async throws {
        let (data, pin) = try PackFixture.make(in: folder.url, teamID: "ABCDE12345")
        let signatures = RecordingSignatures()
        let state = await installer(pin, downloader: MemoryDownloader(bytes: data), signatures: signatures).run(.user)
        #expect(state.name == "installed")
        #expect(await signatures.checked == [
            "Chromium Embedded Framework.framework", "libcmux_cef_shim.dylib",
            "cmux TEST Helper (GPU).app", "cmux TEST Helper (Renderer).app", "cmux TEST Helper.app",
        ])
        #expect(await signatures.teams == ["ABCDE12345"])
    }

    @Test func aBadSignatureIsRefused() async throws {
        let (data, pin) = try PackFixture.make(in: folder.url, teamID: "ABCDE12345")
        let signatures = RecordingSignatures(failing: "Renderer")
        let state = await installer(pin, downloader: MemoryDownloader(bytes: data), signatures: signatures).run(.user)
        #expect(state == .failed(.signature("cmux TEST Helper (Renderer).app"), attempt: 1))
        #expect(store.installations().isEmpty)
    }

    /// p02-threads-053 fixer: a check that never ran (its task cancelled, or quit dropped it) is no failed
    /// attempt. The job ends without `.failed` and without a retry, so nothing reports a false signature failure.
    @Test func aCheckThatNeverRanEndsTheJobWithoutAFailureOrARetry() async throws {
        let (data, pin) = try PackFixture.make(in: folder.url, teamID: "ABCDE12345")
        let signatures = RecordingSignatures(failing: "Renderer", failure: .cancelled)
        let downloader = MemoryDownloader(bytes: data)
        let installer = installer(pin, downloader: downloader, signatures: signatures, maxAttempts: 3)
        let states = await installer.states()
        let state = await installer.run(.user)
        #expect(state == .installing)
        #expect(await downloader.calls == 1, "a dropped check retried the attempt")
        #expect(store.installations().isEmpty)
        var seen: [ChromiumRuntimeInstallState] = []
        for await next in states {
            seen.append(next)
            if next == .installing { break }
        }
        #expect(!seen.contains { if case .failed = $0 { true } else { false } })
    }

    /// p02-threads-053 fixer: each check carries the job's priority, so the checker can run a prefetch's checks at
    /// best effort and a person's at user-visible priority.
    @Test func eachCheckCarriesTheJobPriority() async throws {
        let (data, pin) = try PackFixture.make(in: folder.url, teamID: "ABCDE12345")
        let signatures = RecordingSignatures()
        let state = await installer(pin, downloader: MemoryDownloader(bytes: data), signatures: signatures).run(.background)
        #expect(state.name == "installed")
        #expect(await signatures.priorities == Array(repeating: .background, count: 5))
    }

    @Test func aDevPackSkipsOnlyTheSignatureCheck() async throws {
        let (data, pin) = try PackFixture.make(in: folder.url, teamID: nil)
        let signatures = RecordingSignatures(failing: "")
        let state = await installer(pin, downloader: MemoryDownloader(bytes: data), signatures: signatures).run(.user)
        #expect(state.name == "installed")
        #expect(await signatures.checked.isEmpty)
    }

    @Test func aBackgroundPrefetchWaitsForAnUnmeteredNetworkAndAUserRequestDoesNot() async throws {
        let (data, pin) = try PackFixture.make(in: folder.url)
        let downloader = MemoryDownloader(bytes: data)
        let installer = installer(pin, downloader: downloader, network: FixedNetwork(online: true, unmetered: false), maxAttempts: nil)
        let states = await installer.states()
        await installer.ensure(.background)
        var sawWaiting = false
        for await state in states {
            if state == .waitingForNetwork, !sawWaiting {
                sawWaiting = true
                #expect(await downloader.calls == 0)
                await installer.ensure(.user)
            }
            if state.name == "installed" { break }
        }
        #expect(sawWaiting)
        #expect(await downloader.calls == 1)
    }

    @Test func cleanupAfterAnInstallKeepsThePackInUse() async throws {
        let (oldData, oldPin) = try PackFixture.make(in: folder.url, key: "aaaaaaaaaaaaaaaa")
        let (unusedData, unusedPin) = try PackFixture.make(in: folder.url, key: "bbbbbbbbbbbbbbbb")
        _ = await installer(oldPin, downloader: MemoryDownloader(bytes: oldData)).run(.user)
        // Each install prunes; keep pack a through b's install so the setup holds both.
        _ = await ChromiumRuntimeInstaller(
            pin: unusedPin, store: store, downloader: MemoryDownloader(bytes: unusedData), unpacker: TarChromiumRuntimeUnpacker(),
            signatures: RecordingSignatures(), network: FixedNetwork(), retryDelays: [.zero], maxAttempts: 1,
            keepAlso: { ["aaaaaaaaaaaaaaaa"] }).run(.user)
        #expect(store.installations().map(\.pin.key).sorted() == ["aaaaaaaaaaaaaaaa", "bbbbbbbbbbbbbbbb"])
        let (data, pin) = try PackFixture.make(in: folder.url, key: "cccccccccccccccc")
        let installer = ChromiumRuntimeInstaller(
            pin: pin, store: store, downloader: MemoryDownloader(bytes: data), unpacker: TarChromiumRuntimeUnpacker(),
            signatures: RecordingSignatures(), network: FixedNetwork(), retryDelays: [.zero], maxAttempts: 1,
            keepAlso: { ["aaaaaaaaaaaaaaaa"] })
        #expect(await installer.run(.user).name == "installed")
        #expect(store.installations().map(\.pin.key).sorted() == ["aaaaaaaaaaaaaaaa", "cccccccccccccccc"])
    }
}
