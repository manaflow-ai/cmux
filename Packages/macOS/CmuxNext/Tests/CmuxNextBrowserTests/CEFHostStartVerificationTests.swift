@testable import CmuxNextBrowser
import Foundation
import Testing

/// Task p01-process-101 of plans/cmux-next/chrome-parity/p01-process.md: in host mode cmux never maps
/// or reads the Chromium framework (the Chromium Host does, ChromiumHost/src/host_framework_prefetch.h),
/// and the download's code check stays in cmux: a downloaded runtime is checked before the supervisor
/// is asked for the host that maps it, a refused one never reaches a host. A bundled runtime is covered
/// by the app's signature and is not checked. Against a fake supervisor and a counting check; the
/// host's remote shim never opens (the attach ends at `open`).
@MainActor @Suite(.serialized) struct CEFHostStartVerificationTests {
    @Test func aPreloadInHostModeNeitherReadsNorMapsTheFramework() async {
        VerificationCounts.reset(invalid: nil)
        let runtime = CEFRuntime(storage: CEFProfileStorage(root: Self.scratch()))
        runtime.loadInProcess = { _ in
            VerificationCounts.inProcessLoads += 1
            return .failure(.notEmbedded)
        }
        runtime.hostStart = Self.hostStart(VerificationSupervisor())

        runtime.preload(layout: Self.layout(.bundled))
        await runtime.libraryLoadEnded()

        #expect(runtime.state == .idle, "a preload in host mode began the in-process load")
        #expect(runtime.loadTask == nil)
        #expect(runtime.fencedRead == nil, "a preload in host mode queued the framework read")
        #expect(VerificationCounts.inProcessLoads == 0, "host mode mapped the framework in cmux")
        #expect(runtime.prefetch.last == nil, "host mode read the framework in cmux")
    }

    @Test func aRefusedDownloadedRuntimeNeverAsksForAHost() async {
        VerificationCounts.reset(invalid: CEFRuntimeLayout.frameworkName)
        let supervisor = VerificationSupervisor()

        let result = await Self.hostStart(supervisor).attached(layout: Self.layout(.downloaded(teamID: "ABCDE12345")))

        guard case .failure(.untrusted(let item)) = result else {
            Issue.record("a refused downloaded runtime reached a host: \(result)")
            return
        }
        #expect(item == CEFRuntimeLayout.frameworkName)
        #expect(VerificationCounts.checks == 1)
        #expect(supervisor.asked == 0, "a host was asked to map a runtime the check refused")
    }

    @Test func aDownloadedRuntimeWithoutASigningTeamNeverAsksForAHost() async {
        VerificationCounts.reset(invalid: nil)
        let supervisor = VerificationSupervisor()

        let result = await Self.hostStart(supervisor).attached(layout: Self.layout(.downloaded(teamID: nil)))

        guard case .failure(.untrusted(let item)) = result else {
            Issue.record("an unsigned downloaded runtime reached a host: \(result)")
            return
        }
        #expect(item == "missing Developer ID team")
        #expect(supervisor.asked == 0)
    }

    /// The control: a downloaded runtime the check passes is checked once, then the host is asked for.
    @Test func aCheckedDownloadedRuntimeAsksForTheHost() async {
        VerificationCounts.reset(invalid: nil)
        let supervisor = VerificationSupervisor()

        _ = await Self.hostStart(supervisor).attached(layout: Self.layout(.downloaded(teamID: "ABCDE12345")))

        #expect(VerificationCounts.checks == 1)
        #expect(supervisor.asked == 1)
    }

    /// A sad tab's Reload restarts the host with no layout (`CEFRuntime.restartHost`): the new attach checks
    /// the downloaded runtime the first attach named again, and a runtime changed on disk since never reaches a host.
    @Test func theAttachAfterAHostEndChecksTheFirstLayoutAgain() async {
        VerificationCounts.reset(invalid: nil)
        let supervisor = VerificationSupervisor()
        let start = Self.hostStart(supervisor)
        _ = await start.attached(layout: Self.layout(.downloaded(teamID: "ABCDE12345")))
        start.hostEnded()
        VerificationCounts.invalid = CEFRuntimeLayout.frameworkName

        let result = await start.attached(layout: nil)

        guard case .failure(.untrusted(let item)) = result else {
            Issue.record("a restarted host was asked for with no check: \(result)")
            return
        }
        #expect(item == CEFRuntimeLayout.frameworkName)
        #expect(VerificationCounts.checks == 2)
        #expect(supervisor.asked == 1, "a host was asked to map a runtime the check refused")
    }

    @Test func aBundledRuntimeIsNotCheckedAgain() async {
        VerificationCounts.reset(invalid: CEFRuntimeLayout.frameworkName)
        let supervisor = VerificationSupervisor()

        _ = await Self.hostStart(supervisor).attached(layout: Self.layout(.bundled))

        #expect(VerificationCounts.checks == 0)
        #expect(supervisor.asked == 1)
    }

    /// `CEFRuntime.start` hands its layout to the attach: a refused download fails the start with no host
    /// and no in-process load.
    @Test func theRuntimesStartChecksItsLayoutBeforeTheHost() async {
        VerificationCounts.reset(invalid: CEFRuntimeLayout.frameworkName)
        let supervisor = VerificationSupervisor()
        let runtime = CEFRuntime(storage: CEFProfileStorage(root: Self.scratch()))
        runtime.loadInProcess = { _ in
            VerificationCounts.inProcessLoads += 1
            return .failure(.notEmbedded)
        }
        runtime.hostStart = Self.hostStart(supervisor)

        await #expect(throws: BrowserEngineError.self) {
            try await runtime.start(layout: Self.layout(.downloaded(teamID: "ABCDE12345")), environment: [:], trigger: "test")
        }

        #expect(VerificationCounts.checks == 1)
        #expect(supervisor.asked == 0)
        #expect(VerificationCounts.inProcessLoads == 0)
    }

    private static func hostStart(_ supervisor: VerificationSupervisor) -> CEFHostStart {
        CEFHostStart(supervisor: supervisor, verification: CEFRuntimeVerification(checker: CountingSignatures()),
                     open: { _ in .failure(.notEmbedded) })
    }

    /// A layout under a scratch folder: nothing is on disk, and nothing here reads it.
    private static func layout(_ trust: CEFRuntimeLayout.Trust) -> CEFRuntimeLayout {
        let root = scratch()
        return CEFRuntimeLayout(frameworksDirectory: root, mainBundle: URL(filePath: "/Applications/cmux.app"),
                                helperApp: root.appending(path: "cmux Helper.app"), trust: trust)
    }

    private static func scratch() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "cef-host-verify-\(UUID().uuidString)", directoryHint: .isDirectory)
    }
}

/// What the fakes saw (the suite is serialized).
private nonisolated enum VerificationCounts {
    nonisolated(unsafe) static var checks = 0
    nonisolated(unsafe) static var inProcessLoads = 0
    /// The item ``CountingSignatures`` refuses; nil passes every runtime.
    nonisolated(unsafe) static var invalid: String?

    static func reset(invalid: String?) {
        checks = 0
        inProcessLoads = 0
        self.invalid = invalid
    }
}

/// The downloaded runtime's code check: counts its calls and refuses ``VerificationCounts/invalid`` when set.
private nonisolated struct CountingSignatures: CEFCodeSignatureChecking {
    func invalidItem(in layout: CEFRuntimeLayout, teamID: String) -> String? {
        VerificationCounts.checks += 1
        return VerificationCounts.invalid
    }
}

/// Hands out a wire with no descriptors and counts the requests.
@MainActor
private final class VerificationSupervisor: ChromiumHostSupervising {
    private(set) var asked = 0

    func attachment() async throws(ChromiumHostAttachError) -> ChromiumHostAttachment {
        asked += 1
        return ChromiumHostAttachment(controlFD: -1, remoteShim: URL(filePath: "/nonexistent/libcmux_cef_shim_remote.dylib"),
                                      frameworkLocales: [])
    }

    func observeHostEnds(_ ended: @escaping @MainActor () -> Void) {}
}
