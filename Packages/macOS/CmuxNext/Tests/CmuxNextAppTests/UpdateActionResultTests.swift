import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextUpdater
import Foundation
import Testing

/// `cmux settings check-for-updates` and `install-available-update` answer what happened
/// (claude-sr2 2026-10-26: "Fix the CLI commands so they install, or return a real error, never
/// "target -""): the check returns the running and newest builds or its failure; the install
/// returns once the update installs, with why nothing installs, or with the state it reached.
@MainActor @Suite(.serialized) struct UpdateActionResultTests {
    struct Feed: AppcastFetching {
        let xml: String?
        func fetch(_ url: URL) async throws -> Data {
            guard let xml else { throw URLError(.notConnectedToInternet) }
            return Data(xml.utf8)
        }
    }

    static let newer = """
    <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><title>cmux NIGHTLY</title>
    <item><title>tip</title><sparkle:version>300</sparkle:version><sparkle:shortVersionString>1.1.0</sparkle:shortVersionString></item>
    </channel></rss>
    """

    /// A DEV build's updater (the read-only probe; no Sparkle, no defaults of the user's).
    static func updater(_ xml: String?) -> UpdaterService {
        let identity = UpdateBuildIdentity(bundleIdentifier: "com.cmuxterm.app.debug.update-action-result", shortVersion: "1.0.0",
                                           build: "100", minimumSystemVersion: nil,
                                           infoFeedURL: "https://files-next.cmux.com/nightly-next/appcast-arm64.xml", hasPublicKey: false)
        let defaults = UserDefaults(suiteName: "UpdateActionResultTests.\(UUID().uuidString)")!
        let updater = UpdaterService(identity: identity, policy: ManagedUpdatePolicy { false },
                                     prober: UpdateProber(fetcher: Feed(xml: xml), architecture: .arm64),
                                     defaults: defaults, enableSparkle: false, recordsUpdates: false)
        updater.announcementsFetch = false
        return updater
    }

    /// Runs `id` the way `action.run` does (capturing) and returns its one result.
    static func run(_ id: ActionID, _ updater: UpdaterService) async throws -> Result<[String: ActionResultValue], ActionWorkFailure> {
        let registry = ActionRegistry(catalog: ActionCatalog.all, aliases: ActionCatalog.legacyAliases)
        UpdateHandlers.bind(into: registry, updater: updater)
        let run = registry.capturingRun { _ = registry.perform(id, invocation: ActionInvocation()) }
        #expect(run.results.count == 1, "\(id) answers only `ran`")
        return try await #require(run.results.first).value
    }

    /// The CLI waits for these (`wait`, the 40 s result deadline), not the 2 s control deadline.
    @Test func theUpdateActionsWaitForTheirResult() throws {
        for id: ActionID in ["palette.checkForUpdates", "palette.applyUpdateIfAvailable", "palette.attemptUpdate"] {
            let descriptor = try #require(ActionCatalog.all.first { $0.id == id })
            #expect(descriptor.waitsForResult, "\(id) answers before its result")
        }
        #expect(UpdaterService.installAnswerLimit < ActionDescriptor.resultDeadline)
    }

    @Test func aCheckAnswersTheRunningAndNewestBuilds() async throws {
        let fields = try await Self.run("palette.checkForUpdates", Self.updater(Self.newer)).get()
        #expect(fields["outcome"] == .string("update_available"))
        #expect(fields["current_build"] == .string("100"))
        #expect(fields["newest_build"] == .string("300"))
        #expect(fields["newest_version"] == .string("1.1.0"))
    }

    @Test func aCheckThatFailsIsTheRunsError() async throws {
        guard case .failure(let failure) = try await Self.run("palette.checkForUpdates", Self.updater(nil)) else {
            Issue.record("a failed check answered success")
            return
        }
        #expect(failure.message.hasPrefix("update check failed"))
    }

    @Test func anInstallSettlesOnlyWhenItInstallsOrEnds() throws {
        let updater = Self.updater(Self.newer)
        guard case .answered(let installing)? = updater.installSettled(.installing, moved: false) else {
            Issue.record("installing was not the answer")
            return
        }
        #expect(installing["state"] == .string("installing"))
        #expect(installing["pending"] == .bool(false))
        for phase: UpdateIndicatorPhase in [.checking, .downloading(UpdateTransfer(stage: .downloading, fraction: 0.5)),
                                            .available(version: "300"), .ready(version: "300")] {
            #expect(updater.installSettled(phase, moved: true) == nil, "\(phase) answered before the install")
        }
        // The phase the action returned in (an earlier check's note, the idle start) is not the answer.
        #expect(updater.installSettled(.note(.upToDate), moved: false) == nil)
        #expect(updater.installSettled(.hidden, moved: false) == nil)
        guard case .refused(let upToDate)? = updater.installSettled(.note(.upToDate), moved: true) else {
            Issue.record("up to date was not the run's error")
            return
        }
        #expect(upToDate.contains("100"))
        guard case .refused? = updater.installSettled(.hidden, moved: true) else {
            Issue.record("a check that ended with nothing was not the run's error")
            return
        }
    }

    /// A refusal reaches the CLI as `unavailable` with its reason; a failure as the run's error.
    @Test func anAnswerMapsToTheActionsResult() async throws {
        guard case .failure(let refused) = await UpdateHandlers.result(Task { .refused("why") }).value else {
            Issue.record("a refusal answered success")
            return
        }
        #expect(refused.refusal == .unavailable)
        #expect(refused.message == "why")
        let fields = try await UpdateHandlers.result(Task { .answered(["pending": .bool(true), "progress": .double(0.5)]) }).value.get()
        #expect(fields["pending"] == .bool(true))
        #expect(fields["progress"] == .double(0.5))
    }

    /// An install still in progress at the limit answers the state it reached, never silence.
    @Test func anInstallStillRunningAnswersItsState() async throws {
        let updater = Self.updater(Self.newer)
        updater.debugIndicatorPhase = .downloading(UpdateTransfer(stage: .downloading, fraction: 0.25))
        let fields = try await UpdateHandlers.result(updater.installAnswer(after: updater.settledFlowMoves(), limit: .milliseconds(50))).value.get()
        #expect(fields["pending"] == .bool(true))
        #expect(fields["state"] == .string("downloading"))
    }

    /// A request that failed the same way again (the gate never moved off its note) is the run's
    /// error at the limit, not a pending success.
    @Test func aRepeatedFailureIsTheRunsErrorAtTheLimit() async throws {
        let updater = Self.updater(Self.newer)
        updater.debugIndicatorPhase = .note(.checkFailed)
        let result = await UpdateHandlers.result(updater.installAnswer(after: updater.settledFlowMoves(), limit: .milliseconds(50))).value
        guard case .failure(let failure) = result else {
            Issue.record("a repeated failure answered \(result)")
            return
        }
        #expect(failure.refusal == .unavailable)
    }

    /// Nothing happened by the limit (idle, never moved): the run's error, not a pending success.
    @Test func anInstallThatNeverStartedIsTheRunsError() async throws {
        let updater = Self.updater(Self.newer)
        let result = await UpdateHandlers.result(updater.installAnswer(after: updater.settledFlowMoves(), limit: .milliseconds(50))).value
        guard case .failure = result else {
            Issue.record("an install that never started answered \(result)")
            return
        }
    }

    /// Through the gate's real moves: an earlier check's note is not the answer; the install is.
    @Test func anInstallFollowsTheGateFromTheRequestOn() async throws {
        let updater = Self.updater(Self.newer)
        updater.debugIndicatorPhase = .note(.upToDate)
        let result = UpdateHandlers.result(updater.installAnswer(after: updater.settledFlowMoves(), limit: .seconds(10)))
        await Task.yield()
        updater.debugIndicatorPhase = .downloading(UpdateTransfer(stage: .downloading, fraction: 0.5))
        await Task.yield()
        updater.debugIndicatorPhase = .installing
        let fields = try await result.value.get()
        #expect(fields["state"] == .string("installing"))
        #expect(fields["pending"] == .bool(false))
    }

    /// A failure reported inside the request (before the run starts following) is the run's error,
    /// not a pending success.
    @Test func aFailureInsideTheRequestIsTheRunsError() async throws {
        let updater = Self.updater(Self.newer)
        let baseline = updater.settledFlowMoves()
        updater.debugIndicatorPhase = .note(.checkFailed)
        guard case .failure(let failure) = await UpdateHandlers.result(updater.installAnswer(after: baseline, limit: .seconds(10))).value else {
            Issue.record("a failed install answered success")
            return
        }
        #expect(failure.refusal == .unavailable)
    }

    /// A managed policy that forbids updates refuses the check without reading the feed.
    @Test func aManagedPolicyRefusesTheCheck() async throws {
        // A signed release identity (no Sparkle in the test): the policy is the only reason it is off.
        let identity = UpdateBuildIdentity(bundleIdentifier: "com.cmuxterm.app.nightly.update-action-result", shortVersion: "1.0.0",
                                           build: "100", minimumSystemVersion: nil,
                                           infoFeedURL: "https://files-next.cmux.com/nightly-next/appcast-arm64.xml", hasPublicKey: true)
        let defaults = try #require(UserDefaults(suiteName: "UpdateActionResultTests.\(UUID().uuidString)"))
        let updater = UpdaterService(identity: identity, policy: ManagedUpdatePolicy { true },
                                     prober: UpdateProber(fetcher: Feed(xml: Self.newer), architecture: .arm64),
                                     defaults: defaults, enableSparkle: false, recordsUpdates: false)
        updater.announcementsFetch = false
        guard case .managedPolicy? = updater.disabledReason else {
            Issue.record("the policy is not why updates are off: \(String(describing: updater.disabledReason))")
            return
        }
        guard case .failure(let failure) = try await Self.run("palette.checkForUpdates", updater) else {
            Issue.record("a managed policy's check answered the feed")
            return
        }
        #expect(failure.refusal == .unavailable)
        #expect(updater.lastProbe == nil, "the check read the feed")
    }

    @Test func aDownloadingStateCarriesItsProgress() {
        let fields = UpdaterService.state(.downloading(UpdateTransfer(stage: .downloading, fraction: 0.25)), pending: true)
        #expect(fields["state"] == .string("downloading"))
        #expect(fields["progress"] == .double(0.25))
    }
}
