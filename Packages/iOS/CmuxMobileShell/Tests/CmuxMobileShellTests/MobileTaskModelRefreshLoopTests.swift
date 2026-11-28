import CMUXMobileCore
import CmuxMobileRPC
import Foundation
import Testing
@testable import CmuxMobileShell
import CmuxMobileShellModel

@MainActor
@Suite struct MobileTaskModelRefreshLoopTests {
    @Test func retriesBeyondThreeAttemptsWithCappedDelayUntilSuccess() async {
        var requests = 0
        var delays: [Duration] = []
        await MobileTaskModelRefreshLoop().run(
            refresh: {
                requests += 1
                return requests == 11 ? .succeeded : .retry(.timedOut)
            },
            sleep: { delays.append($0) }
        )
        #expect(requests == 11)
        #expect(delays == [500, 1_000, 2_000, 4_000, 8_000, 15_000,
                           15_000, 15_000, 15_000, 15_000].map(Duration.milliseconds))
    }

    @Test func stopsImmediatelyForExplicitPermanentFailure() async {
        var requests = 0
        var sleeps = 0
        await MobileTaskModelRefreshLoop().run(
            refresh: { requests += 1; return .stopped(.unsupported) },
            sleep: { _ in sleeps += 1 }
        )
        #expect(requests == 1)
        #expect(sleeps == 0)
    }

    @Test func dismissalDuringBackoffStopsFurtherFetches() async {
        var isCurrent = true
        var requests = 0
        await MobileTaskModelRefreshLoop().run(
            shouldContinue: { isCurrent },
            refresh: { requests += 1; return .retry(.connectionClosed) },
            sleep: { _ in isCurrent = false }
        )
        #expect(requests == 1)
    }

    @Test func cancellationDuringBackoffStopsFurtherFetches() async {
        var requests = 0
        let sleeping = AsyncStream<Void>.makeStream()
        let task = Task {
            await MobileTaskModelRefreshLoop().run(
                refresh: { requests += 1; return .retry(.unknown) },
                sleep: { _ in
                    sleeping.continuation.yield(())
                    try await Task.sleep(for: .seconds(60))
                }
            )
        }
        for await _ in sleeping.stream { break }
        task.cancel()
        await task.value
        sleeping.continuation.finish()
        #expect(requests == 1)
    }

    @Test func unknownAndTemporaryErrorsRemainRetryable() {
        for error in [
            MobileShellConnectionError.requestTimedOut,
            .connectionClosed, .invalidResponse, .connectAttemptGated,
            .rpcError("request_timeout", "fixture"),
            .rpcError("unknown_new_error", "fixture"),
        ] {
            guard case .retry = MobileTaskModelRefreshOutcome(classifying: error) else {
                Issue.record("Temporary or unknown error stopped discovery")
                continue
            }
        }
    }

    @Test func onlyExplicitPermanentErrorsStopRetries() {
        #expect(MobileTaskModelRefreshOutcome(classifying:
            MobileShellConnectionError.rpcError("method_not_found", "fixture")
        ) == .stopped(.unsupported))
        #expect(MobileTaskModelRefreshOutcome(classifying:
            MobileShellConnectionError.rpcError("capability_disabled", "fixture")
        ) == .stopped(.disabled))
        #expect(MobileTaskModelRefreshOutcome(classifying:
            MobileShellConnectionError.authorizationFailed("fixture")
        ) == .stopped(.authorizationRequired))
        #expect(MobileTaskModelRefreshOutcome(classifying:
            MobileShellConnectionError.accountMismatch("fixture")
        ) == .stopped(.accountMismatch))
        #expect(MobileTaskModelRefreshOutcome(classifying:
            MobileShellConnectionError.rpcError("invalid_params", "fixture")
        ) == .stopped(.invalidRequest))
    }

    @Test func usableBackendDoesNotEndHostRetriesOrLoseCachedModels() async {
        let model = MobileTaskAgentModel(id: "backend-model", displayName: "Backend")
        let store = MobileShellComposite(taskModelCatalogClient: MobileTaskModelCatalogClient(
            endpoint: URL(string: "https://catalog.example.test/models")!,
            loader: { _ in
                Data(#"{"schemaVersion":1,"providers":{"codex":{"models":[{"id":"backend-model","label":"Backend"}]}}}"#.utf8)
            }
        ))
        var visible: [MobileTaskModelListResult] = []
        let outcome = await store.refreshTaskModels(
            provider: .codex, macDeviceID: "offline-mac", instanceTag: nil,
            didUpdate: { visible.append($0) }
        )
        #expect(outcome == .retry(.connectionClosed))
        #expect(visible.last?.models == [model])
        #expect(visible.last?.error == nil)
    }
}
