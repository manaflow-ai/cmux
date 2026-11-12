import AppKit
import CmuxNextDevices
@testable import CmuxNextMacScreen
import CmuxNextWakeups
import Foundation
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
        // Round 6 (verifier non-blocking 5): a hub never started is past the same deadline.
        let idle = MacScreenHomeSnapshot.noDevicesShown(status: .idle, listed: false, listFailed: true)
        guard case .failed = idle else {
            Issue.record("a hub never started, past its deadline, showed \(idle)")
            return
        }
    }

    /// Round 8 (verifier M8, blocking 3): Settings › Devices passed the other devices without their
    /// list state, so a hub whose list was not read yet, failed or timed out said "Sign in to cmux
    /// on your other Macs…" with no error and no Try Again. The card now gets `othersRead`.
    @Test func settingsOtherDevicesSayNoneOnlyOnceTheListWasRead() {
        typealias Settings = MacScreenDevicesSettings
        for status in [DeviceHub.Status.idle, .starting, .ready] {
            #expect(Settings.othersRead(status: status, listed: false, any: false, listFailed: false) == .loading,
                    "\(status) with no list read was not loading")
            #expect(Settings.othersRead(status: status, listed: false, any: false, listFailed: true) == .failed,
                    "\(status) with a failed or timed-out list read was not the error")
        }
        #expect(Settings.othersRead(status: .failed("offline"), listed: false, any: false, listFailed: false) == .failed)
        #expect(Settings.othersRead(status: .ready, listed: true, any: false, listFailed: false) == .listed)
        // Devices already read stay listed while a later read fails.
        #expect(Settings.othersRead(status: .ready, listed: true, any: true, listFailed: true) == .listed)
    }

    /// The card's state carries the list state and its error copy (the page reads `othersRead`,
    /// `labels.othersFailed` and `labels.othersRetry`).
    @Test func settingsStateEncodesTheOtherDevicesReadState() throws {
        let labels = MacScreenDevicesSettings.Labels.current
        #expect(labels.othersFailed == L.t("macScreen.home.devicesFailed", "Couldn’t reach the device hub to load your devices."))
        var state = MacScreenDevicesSettings.State(available: true, status: .init(text: "Connected", tone: "success"), signIn: nil,
                                                   error: nil, labels: labels, thisDevice: nil, others: [], sharing: nil,
                                                   relays: [], history: [])
        state.othersRead = .failed
        let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        #expect(json["othersRead"] as? String == "failed")
        let encodedLabels = try #require(json["labels"] as? [String: Any])
        #expect(encodedLabels["othersRetry"] as? String == L.t("macScreen.card.retry", "Try Again"))
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
