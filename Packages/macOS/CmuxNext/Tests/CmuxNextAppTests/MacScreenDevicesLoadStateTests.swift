import AppKit
import CmuxNextDevices
@testable import CmuxNextMacScreen
import CmuxNextWakeups
import Testing

/// ui-state-fixes M5: Your Devices said "None of your other devices share Mac Screen" while the hub
/// had not started (`idle`) and "Loading your devices…" forever when it failed. An empty list is
/// "none shared" only once the hub is registered and the list was read; before that it is
/// loading; a failure is an error with Try Again.
@MainActor @Suite struct MacScreenDevicesLoadStateTests {
    let noneShared = L.t("macScreen.home.noSharedDevices", "None of your other devices share Mac Screen. On the Mac you want to see, turn on Allow Mac Screen on this Mac.")
    let loading = L.t("macScreen.home.devicesLoading", "Loading your devices…")

    @Test func anIdleOrStartingHubIsLoading() {
        for status in [DeviceHub.Status.idle, .starting] {
            let shown = MacScreenHomeSnapshot.noDevicesShown(status: status, listed: false, listFailed: false)
            #expect(shown == .note(loading), "\(status) said no device shares Mac Screen")
        }
    }

    @Test func aReadyHubIsLoadingUntilItsListIsRead() {
        #expect(MacScreenHomeSnapshot.noDevicesShown(status: .ready, listed: false, listFailed: false) == .note(loading))
        #expect(MacScreenHomeSnapshot.noDevicesShown(status: .ready, listed: true, listFailed: false) == .note(noneShared))
    }

    @Test func aFailureIsAnErrorWithRetryNotLoading() {
        let failed = MacScreenHomeSnapshot.noDevicesShown(status: .failed("offline"), listed: false, listFailed: false)
        guard case .failed = failed else {
            Issue.record("a failed hub showed \(failed)")
            return
        }
        let unread = MacScreenHomeSnapshot.noDevicesShown(status: .ready, listed: false, listFailed: true)
        guard case .failed = unread else {
            Issue.record("a failed list read showed \(unread)")
            return
        }
    }

    /// Round 2 (verifier M-3): a registration that never answered is past its deadline
    /// (`DeviceHub.devicesListTimedOut`, read as `listFailed`): the error with Try Again, not loading.
    @Test func aStartPastItsDeadlineIsAnErrorNotLoading() {
        let shown = MacScreenHomeSnapshot.noDevicesShown(status: .starting, listed: false, listFailed: true)
        guard case .failed = shown else {
            Issue.record("a start past its deadline showed \(shown)")
            return
        }
        #expect(MacScreenHomeSnapshot.noDevicesShown(status: .idle, listed: false, listFailed: true) == .note(loading))
    }

    /// Round 2 (verifier M-1): Try Again sat flush at the card's bottom-left, a bare stack member
    /// beside the padded note. It shares the note's padded column: the same leading edge as the
    /// note's text, and the card's 14 pt inset below it.
    @Test func tryAgainSharesTheNotesInsetAndLeadingEdge() throws {
        let home = MacScreenHomeView(host: MacScreenShareHost(work: BackgroundWork()), actions: MacScreenHomeActions())
        home.frame = NSRect(x: 0, y: 0, width: 720, height: 640)
        let failedText = L.t("macScreen.home.devicesFailed", "Couldn’t reach the device hub to load your devices.")
        home.build(MacScreenHomeSnapshot(devices: .failed(failedText), sharingLook: .list))
        home.layoutPage()
        home.layoutSubtreeIfNeeded()
        let all = Self.views(under: home)
        let retry = try #require(all.first { $0.accessibilityIdentifier() == "macScreen.home.devicesRetry" })
        let note = try #require(all.compactMap { $0 as? MacScreenText }.first { $0.stringValue == failedText })
        let card = try #require(Self.ancestor(of: retry) { $0 is MacScreenFill })
        #expect(Self.ancestor(of: note) { $0 === card } != nil, "the note and Try Again are in different cards")
        let retryRect = card.convert(retry.alignmentRect(forFrame: retry.frame), from: retry.superview)
        let noteRect = card.convert(note.alignmentRect(forFrame: note.frame), from: note.superview)
        #expect(abs(retryRect.minX - noteRect.minX) < 0.5, "Try Again at x \(retryRect.minX), the note's text at \(noteRect.minX)")
        #expect(retryRect.minX >= 14 - 0.5, "Try Again has no leading inset (x \(retryRect.minX))")
        let below = card.isFlipped ? card.bounds.maxY - retryRect.maxY : retryRect.minY - card.bounds.minY
        #expect(below >= 14 - 0.5, "Try Again sits \(below) pt from the card's bottom")
    }

    private static func views(under root: NSView) -> [NSView] {
        root.subviews.flatMap { [$0] + views(under: $0) }
    }

    private static func ancestor(of view: NSView, where match: (NSView) -> Bool) -> NSView? {
        var next = view.superview
        while let current = next {
            if match(current) { return current }
            next = current.superview
        }
        return nil
    }
}
