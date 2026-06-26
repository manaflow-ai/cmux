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

        // The active prompt is dismissed and the updater re-checks.
        #expect(coordinator.handleStateChange(.idle) == .none)
        #expect(coordinator.handleStateChange(.checking(.init(cancel: {}))) == .none)

        // The fresh check resolves the newer version — install THAT one.
        #expect(coordinator.handleStateChange(updateAvailable("0.64.16")) == .confirmInstall)
        #expect(!coordinator.isMonitoring)
    }

    /// A lingering repeat of the pre-request prompt (before the fresh check actually restarts) must
    /// be ignored, so we never confirm the stale version even if Sparkle re-emits it.
    @Test func ignoresStalePromptUntilCheckRestarts() {
        var coordinator = AttemptUpdateCoordinator()
        _ = coordinator.requestInstallLatest(currentState: updateAvailable("0.64.15"))

        // Same prompt re-emitted before any restart signal: do not install it.
        #expect(coordinator.handleStateChange(updateAvailable("0.64.15")) == .none)
        #expect(coordinator.isMonitoring)

        // Once the check restarts and resolves the latest, confirm that one.
        #expect(coordinator.handleStateChange(.checking(.init(cancel: {}))) == .none)
        #expect(coordinator.handleStateChange(updateAvailable("0.64.16")) == .confirmInstall)
    }

    @Test func confirmsFromIdleDetectedPath() {
        var coordinator = AttemptUpdateCoordinator()
        _ = coordinator.requestInstallLatest(currentState: .idle)

        #expect(coordinator.handleStateChange(.checking(.init(cancel: {}))) == .none)
        #expect(coordinator.handleStateChange(updateAvailable("0.64.16")) == .confirmInstall)
        #expect(!coordinator.isMonitoring)
    }

    @Test func doesNotInterruptAnInProgressInstall() {
        for state: UpdateState in [
            .downloading(.init(cancel: {}, expectedLength: 100, progress: 10)),
            .extracting(.init(progress: 0.5)),
            .installing(.init(retryTerminatingApplication: {}, dismiss: {})),
        ] {
            var coordinator = AttemptUpdateCoordinator()
            #expect(coordinator.requestInstallLatest(currentState: state) == .none)
            #expect(!coordinator.isMonitoring)
        }
    }

    @Test func stopsMonitoringWhenFreshCheckFindsNothing() {
        var coordinator = AttemptUpdateCoordinator()
        _ = coordinator.requestInstallLatest(currentState: updateAvailable("0.64.15"))
        #expect(coordinator.handleStateChange(.idle) == .none)
        #expect(coordinator.handleStateChange(.checking(.init(cancel: {}))) == .none)
        #expect(coordinator.handleStateChange(.notFound(.init(acknowledgement: {}))) == .none)
        #expect(!coordinator.isMonitoring)
    }

    @Test func stopsMonitoringWhenFreshCheckErrors() {
        var coordinator = AttemptUpdateCoordinator()
        _ = coordinator.requestInstallLatest(currentState: .idle)
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
