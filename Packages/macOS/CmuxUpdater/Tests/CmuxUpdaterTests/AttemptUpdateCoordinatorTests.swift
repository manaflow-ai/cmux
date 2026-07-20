import Foundation
import Testing
@preconcurrency import Sparkle
@testable import CmuxUpdater

/// Tests for ``AttemptUpdateCoordinator`` — the policy that makes the install path re-resolve to
/// the latest available version instead of installing the version captured when the prompt was
/// first surfaced (issue #6366).
@MainActor
@Suite struct AttemptUpdateCoordinatorTests {
    private func updateAvailable(_ version: String) -> UpdateState {
        let item = SUAppcastItem(dictionary: [
            "title": "cmux \(version)",
            "pubDate": "Wed, 25 Mar 2026 12:00:00 +0000",
            "enclosure": [
                "url": "https://example.com/cmux.zip",
                "length": "1024",
                "sparkle:version": version,
                "sparkle:shortVersionString": version,
            ],
        ]) ?? SUAppcastItem.empty()
        return .updateAvailable(.init(appcastItem: item, reply: { _ in }))
    }

    /// Regression for #6366: requesting an install while an update prompt is already on screen must
    /// NOT install that captured (possibly stale) version. It must start a fresh check so the feed
    /// is re-resolved to the latest available version.
    @Test func requestWhileUpdateShowingReResolvesInsteadOfInstallingCapturedVersion() {
        var coordinator = AttemptUpdateCoordinator()

        let action = coordinator.requestInstallLatest(currentState: updateAvailable("0.64.15"))

        #expect(action == .startFreshCheck)
        #expect(action != .confirmInstall)
        #expect(coordinator.isMonitoring)
    }

    @Test func requestFromIdleStartsFreshCheck() {
        var coordinator = AttemptUpdateCoordinator()
        let action = coordinator.requestInstallLatest(currentState: .idle)
        #expect(action == .startFreshCheck)
        #expect(coordinator.isMonitoring)
    }

    /// The full active-prompt sequence: the stale prompt is dismissed (idle), a new check runs
    /// (checking), and the freshly resolved newer version is the one confirmed for install.
    @Test func confirmsTheVersionResolvedByTheFreshCheck() {
        var coordinator = AttemptUpdateCoordinator()
        _ = coordinator.requestInstallLatest(currentState: updateAvailable("0.64.15"))

        // The lifecycle owner invokes Sparkle only after the old cycle finishes.
        coordinator.didStartFreshCheck()
        #expect(coordinator.handleStateChange(.checking(.init(cancel: {}))) == .none)

        // The fresh check resolves the newer version — install THAT one.
        #expect(coordinator.handleStateChange(updateAvailable("0.64.16")) == .confirmInstall)
        #expect(coordinator.isMonitoring)
        #expect(coordinator.handleStateChange(.startingDownload) == .none)
        #expect(coordinator.handleStateChange(.downloading(.init(cancel: {}, expectedLength: nil, progress: 0))) == .none)
        #expect(!coordinator.isMonitoring)
    }

    /// An unattributed idle cannot be interpreted as user cancellation. It is a failed accepted
    /// install that the controller must turn into a retryable error.
    @Test func unattributedIdleBeforeFreshCheckFailsInstall() {
        var coordinator = AttemptUpdateCoordinator()
        _ = coordinator.requestInstallLatest(currentState: updateAvailable("0.64.15"))

        #expect(coordinator.handleStateChange(.idle) == .installFailed)
        #expect(!coordinator.isMonitoring)
    }

    /// A lingering repeat of the pre-request prompt (before the fresh check actually restarts) must
    /// be ignored, so we never confirm the stale version even if Sparkle re-emits it.
    @Test func ignoresStalePromptUntilCheckRestarts() {
        var coordinator = AttemptUpdateCoordinator()
        _ = coordinator.requestInstallLatest(currentState: updateAvailable("0.64.15"))

        #expect(coordinator.handleStateChange(.preparingCheck(.init(cancel: {}))) == .none)
        // Once the controller starts the check and it resolves the latest, confirm that one.
        coordinator.didStartFreshCheck()
        #expect(coordinator.handleStateChange(.checking(.init(cancel: {}))) == .none)
        #expect(coordinator.handleStateChange(updateAvailable("0.64.16")) == .confirmInstall)
    }

    @Test func confirmsFromIdleDetectedPath() {
        var coordinator = AttemptUpdateCoordinator()
        _ = coordinator.requestInstallLatest(currentState: .idle)

        coordinator.didStartFreshCheck()
        #expect(coordinator.handleStateChange(.checking(.init(cancel: {}))) == .none)
        #expect(coordinator.handleStateChange(updateAvailable("0.64.16")) == .confirmInstall)
        #expect(coordinator.isMonitoring)
    }

    @Test func doesNotInterruptAnInProgressInstall() {
        for state: UpdateState in [
            .downloading(.init(cancel: {}, expectedLength: 100, progress: 10)),
            .extracting(.init(progress: 0.5)),
            .installing(.init(retryTerminatingApplication: {}, dismiss: {})),
            .startingDownload,
        ] {
            var coordinator = AttemptUpdateCoordinator()
            #expect(coordinator.requestInstallLatest(currentState: state) == .none)
            #expect(!coordinator.isMonitoring)
        }
    }

    @Test func stopsMonitoringWhenFreshCheckFindsNothing() {
        var coordinator = AttemptUpdateCoordinator()
        _ = coordinator.requestInstallLatest(currentState: updateAvailable("0.64.15"))
        coordinator.didStartFreshCheck()
        #expect(coordinator.handleStateChange(.checking(.init(cancel: {}))) == .none)
        #expect(coordinator.handleStateChange(.notFound(.init(acknowledgement: {}))) == .installFailed)
        #expect(!coordinator.isMonitoring)
    }

    /// Regression: if the user cancels the in-flight fresh check (Cancel in the checking popover,
    /// which returns the model to idle), the coordinator must stop monitoring. Otherwise it lingers
    /// and silently auto-installs the result of the next unrelated user-triggered check.
    @Test func cancellingFreshCheckStopsMonitoringSoLaterCheckIsNotAutoInstalled() {
        var coordinator = AttemptUpdateCoordinator()
        _ = coordinator.requestInstallLatest(currentState: .idle)
        coordinator.didStartFreshCheck()
        #expect(coordinator.handleStateChange(.checking(.init(cancel: {}))) == .none)

        // The controller receives the causal user-cancel signal before Sparkle emits idle.
        coordinator.cancel()
        #expect(!coordinator.isMonitoring)

        // A later, unrelated check that finds an update must NOT be auto-confirmed.
        #expect(coordinator.handleStateChange(updateAvailable("0.64.16")) == .none)
    }

    /// The active-prompt cancel path: the stale prompt is dismissed (idle), the check restarts
    /// (checking), then the user cancels (idle again) — the coordinator must stop, not linger.
    @Test func cancellingAfterActivePromptDismissStopsMonitoring() {
        var coordinator = AttemptUpdateCoordinator()
        _ = coordinator.requestInstallLatest(currentState: updateAvailable("0.64.15"))
        coordinator.didStartFreshCheck()
        #expect(coordinator.handleStateChange(.checking(.init(cancel: {}))) == .none)
        coordinator.cancel()
        #expect(!coordinator.isMonitoring)
        #expect(coordinator.handleStateChange(updateAvailable("0.64.16")) == .none)
    }

    @Test func stopsMonitoringWhenFreshCheckErrors() {
        var coordinator = AttemptUpdateCoordinator()
        _ = coordinator.requestInstallLatest(currentState: .idle)
        coordinator.didStartFreshCheck()
        #expect(coordinator.handleStateChange(.checking(.init(cancel: {}))) == .none)
        let error = UpdateState.error(.init(error: NSError(domain: "t", code: 1), retry: {}, dismiss: {}))
        #expect(coordinator.handleStateChange(error) == .none)
        #expect(!coordinator.isMonitoring)
    }

    @Test func cancelStopsMonitoring() {
        var coordinator = AttemptUpdateCoordinator()
        _ = coordinator.requestInstallLatest(currentState: .idle)
        #expect(coordinator.isMonitoring)
        coordinator.cancel()
        #expect(!coordinator.isMonitoring)
        // After cancel, further state changes are ignored.
        #expect(coordinator.handleStateChange(updateAvailable("0.64.16")) == .none)
    }

    /// An idle coordinator never reacts to background state changes.
    @Test func inactiveCoordinatorIgnoresStateChanges() {
        var coordinator = AttemptUpdateCoordinator()
        #expect(!coordinator.isMonitoring)
        #expect(coordinator.handleStateChange(updateAvailable("0.64.16")) == .none)
        #expect(coordinator.handleStateChange(.notFound(.init(acknowledgement: {}))) == .none)
    }
}
