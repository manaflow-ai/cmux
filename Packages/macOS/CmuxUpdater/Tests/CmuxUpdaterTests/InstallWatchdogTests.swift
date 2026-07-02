import Foundation
import Testing
@preconcurrency import Sparkle
@testable import CmuxUpdater

/// Tests for the install watchdog's decision logic in ``InstallWatchdog``.
///
/// The watchdog exists to guarantee the user is never left staring at a silent "Update Available"
/// pill after clicking Install: if the flow never reaches downloading/installing (or another
/// visible outcome) within ``UpdateTiming/installWatchdogTimeout``, a visible "Update Didn't
/// Start" error is surfaced. These tests pin the two pure predicates that drive arming/firing so
/// the classification can't silently drift.
@MainActor
@Suite struct InstallWatchdogTests {
    private func updateAvailable(_ version: String = "0.64.16") -> UpdateState {
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

    private var everyState: [UpdateState] {
        [
            .idle,
            .permissionRequest(.init(request: SPUUpdatePermissionRequest(systemProfile: []), reply: { _ in })),
            .checking(.init(cancel: {})),
            updateAvailable(),
            .notFound(.init(acknowledgement: {})),
            .error(.init(error: NSError(domain: "t", code: 1), retry: {}, dismiss: {})),
            .downloading(.init(cancel: {}, expectedLength: 100, progress: 10)),
            .extracting(.init(progress: 0.5)),
            .installing(.init(retryTerminatingApplication: {}, dismiss: {})),
        ]
    }

    /// The watchdog only reports a stall while the user is still waiting on a check or an unacted
    /// "Update Available" — the exact states the double-idle bug got stuck in.
    @Test func stalledOnlyForCheckingAndUpdateAvailable() {
        for state in everyState {
            let stalled = InstallWatchdog.installAttemptStalled(state)
            switch state {
            case .checking, .updateAvailable:
                #expect(stalled, "\(state) should count as stalled")
            default:
                #expect(!stalled, "\(state) should NOT count as stalled")
            }
        }
    }

    /// Download/extract/install progress and clearly-communicated terminals (notFound/error)
    /// disarm the watchdog; idle/permissionRequest/checking/updateAvailable do not.
    @Test func resolvedForProgressAndVisibleTerminals() {
        for state in everyState {
            let resolved = InstallWatchdog.installAttemptResolved(state)
            switch state {
            case .downloading, .extracting, .installing, .notFound, .error:
                #expect(resolved, "\(state) should resolve/disarm the watchdog")
            default:
                #expect(!resolved, "\(state) should NOT resolve the watchdog")
            }
        }
    }

    /// A state is never simultaneously "stalled" and "resolved": the two predicates must not
    /// overlap, or arming and firing would race.
    @Test func stalledAndResolvedAreMutuallyExclusive() {
        for state in everyState {
            #expect(!(InstallWatchdog.installAttemptStalled(state) && InstallWatchdog.installAttemptResolved(state)))
        }
    }

    /// The watchdog error renders with its own copy, not the generic "Update Failed" catch-all.
    @Test func watchdogErrorRendersDedicatedCopy() {
        let error = NSError(
            domain: UpdateStateModel.updateErrorDomain,
            code: UpdateStateModel.installDidNotStartCode,
            userInfo: [NSLocalizedDescriptionKey: "cmux couldn’t start the update. Check your internet connection and try again."]
        )
        let title = UpdateStateModel.userFacingErrorTitle(for: error)
        let message = UpdateStateModel.userFacingErrorMessage(for: error)
        #expect(title == "Update Didn’t Start")
        #expect(message.contains("couldn’t start the update"))
        #expect(title != "Update Failed")
    }
}
