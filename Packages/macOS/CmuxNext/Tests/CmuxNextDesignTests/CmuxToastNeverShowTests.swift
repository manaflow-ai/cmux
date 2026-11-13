import AppKit
@testable import CmuxNextDesign
import CmuxNextDesignTokens
import CmuxNextTestSupport
import CmuxNextWakeupsTestSupport
import Testing

/// Never show again, and longer toasts (Lawrence 2026-11-12: "for all the toasts that disappear
/// eventually, we should have an X for never show again; and we should show the toasts for longer
/// too"). A toast that ends on its own carries Don't Show Again; the kind the person hides stays
/// hidden across launches (the store's defaults) until Settings shows them again. Undo toasts and
/// toasts that wait for an answer never offer it: hiding them would hide the person's way back.
@MainActor
@Suite(.closesItsWindows)
struct CmuxToastNeverShowTests {
    private static func window() -> NSWindow {
        NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.borderless],
                 backing: .buffered, defer: true)
    }

    private static func store() -> CmuxToastNeverShowStore {
        CmuxToastNeverShowStore(defaults: UserDefaults(testSuiteName: "toast-never-show-\(UUID().uuidString)")!)
    }

    /// Don't Show Again ends the toast, and the same kind never shows again, in any window.
    @Test func dontShowAgainHidesTheKindForGood() {
        let host = NeverShowRecordingHost()
        let center = CmuxToastCenter(host: host, neverShow: Self.store())
        let window = Self.window()
        let other = Self.window()
        defer { window.closeAfterTest(); other.closeAfterTest() }
        let notice = CmuxToast(id: "cloud-close-keeps-machine", message: "The Cloud machine keeps running until 5 PM")
        center.show(notice, in: window)
        host.neverShowNewest()
        #expect(center.toasts(in: window).isEmpty)

        // Long after the close button's quiet time: still hidden, also with another message.
        let again = center.show(CmuxToast(id: "cloud-close-keeps-machine", message: "Keeps running until 6 PM"), in: other)
        #expect(again.isDismissed)
        #expect(center.toasts(in: other).isEmpty)
        // Another kind still shows.
        let unrelated = center.show(CmuxToast(id: "density", message: "Compact"), in: window)
        #expect(!unrelated.isDismissed)
        unrelated.dismiss()
    }

    /// A toast whose id carries a path or a session hides by its `kind`, so one click hides every
    /// file's copy, not only this file's.
    @Test func theKindNotTheIdIsHidden() {
        let host = NeverShowRecordingHost()
        let center = CmuxToastCenter(host: host, neverShow: Self.store())
        let window = Self.window()
        defer { window.closeAfterTest() }
        center.show(CmuxToast(id: "file-recovery:/a.txt", kind: "file-recovery", message: "No recovered copy of a.txt"), in: window)
        host.neverShowNewest()
        let next = center.show(CmuxToast(id: "file-recovery:/b.txt", kind: "file-recovery", message: "No recovered copy of b.txt"), in: window)
        #expect(next.isDismissed)
    }

    /// The choice lasts: a new store over the same defaults (the next launch) still hides the kind,
    /// and Show Hidden Toasts brings every kind back.
    @Test func theChoiceLastsUntilShownAgain() {
        let defaults = UserDefaults(testSuiteName: "toast-never-show-\(UUID().uuidString)")!
        CmuxToastNeverShowStore(defaults: defaults).hide("density")
        let relaunched = CmuxToastNeverShowStore(defaults: defaults)
        #expect(relaunched.isHidden("density"))
        #expect(relaunched.hiddenKinds == ["density"])
        relaunched.showAll()
        #expect(!CmuxToastNeverShowStore(defaults: defaults).isHidden("density"))
    }

    /// Undo toasts and toasts that wait for an answer never offer it, and a stray report for one hides nothing.
    @Test func undoAndAnswerToastsCannotBeHidden() {
        let undo = CmuxToast(id: "tab-closed", message: "Closed “zsh”", action: .undo())
        let prompt = CmuxToast(id: "server-update", message: "Update the server?", duration: CmuxToast.untilClosed)
        let notice = CmuxToast(id: "density", message: "Compact")
        #expect(!undo.offersNeverShow)
        #expect(!prompt.offersNeverShow)
        #expect(notice.offersNeverShow)

        let host = NeverShowRecordingHost()
        let store = Self.store()
        let center = CmuxToastCenter(host: host, neverShow: store)
        let window = Self.window()
        defer { window.closeAfterTest() }
        center.show(undo, in: window)
        host.neverShowNewest()
        #expect(store.hiddenKinds.isEmpty)
        #expect(center.toasts(in: window).count == 1)
    }

    /// The toast draws Don't Show Again beside close only when it offers it.
    @Test func theButtonShowsOnlyWhereItApplies() throws {
        let notice = CmuxToastView(toast: CmuxToast(id: "density", message: "Compact"))
        let button = try #require(notice.neverShowButton)
        #expect(button.accessibilityLabel() == CmuxToastStrings.dontShowAgain)
        #expect(button.accessibilityIdentifier() == "cmux.toast.density.neverShow")
        #expect(CmuxToastView(toast: CmuxToast(id: "t", message: "Closed", action: .undo())).neverShowButton == nil)
    }

    /// Toasts show longer: twice their asked time, never under six seconds; a toast that echoes a
    /// live change (zoom percent, density) keeps its exact time.
    @Test func toastsShowLonger() {
        let tuning = CmuxToastTuning()
        #expect(tuning.shownDuration(of: CmuxToast(id: "a", message: "m")) == .seconds(12))
        #expect(tuning.shownDuration(of: CmuxToast(id: "a", message: "m", duration: .seconds(2))) == .seconds(6))
        #expect(tuning.shownDuration(of: CmuxToast(id: "z", message: "110%", duration: .seconds(1), keepsDuration: true)) == .seconds(1))
        #expect(tuning.shownDuration(of: CmuxToast(id: "p", message: "?", duration: CmuxToast.untilClosed)) == CmuxToast.untilClosed)
    }

    /// The center times a toast by the tuned duration, not the asked one.
    @Test(.timeLimit(.minutes(1))) func theCenterWaitsTheLongerTime() async throws {
        let host = NeverShowRecordingHost()
        let clock = ManualClock()
        let center = CmuxToastCenter(clock: clock, host: host, neverShow: Self.store())
        let window = Self.window()
        defer { window.closeAfterTest() }
        let handle = center.show(CmuxToast(id: "a", message: "Saved", duration: .seconds(6)), in: window)
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(7))
        #expect(!handle.isDismissed, "a 6 s toast ended at its old time")
        handle.dismiss()
    }

    /// The toast tuning tool's knobs are Debug Settings tunables (section Toasts): an override there
    /// is what the next toast is built and timed with, and the override file is what Save keeps.
    @Test func theTuningReadsTheDebugSettingsOverrides() {
        let store = TunableStore()
        store.register(CmuxToastTunables.all)
        store.activate(file: nil)
        store.set(CmuxToastTunables.durationScale.key, .number(3))
        store.set(CmuxToastTunables.glass.key, CmuxToastGlass.frost.tunableValue)
        store.set(CmuxToastTunables.horizontalPadding.key, .number(20))
        let tuning = CmuxToastTuning(store: store)
        #expect(tuning.durationScale == 3)
        #expect(tuning.glass == .frost)
        #expect(tuning.horizontalPadding == 20)
        #expect(tuning.shownDuration(of: CmuxToast(id: "a", message: "m")) == .seconds(18))
        #expect(CmuxToastTuning(store: TunableStore()) == CmuxToastTuning())
    }
}

/// Records what the center gives it and plays the person's Don't Show Again on the newest toast.
@MainActor
private final class NeverShowRecordingHost: CmuxToastHosting {
    private(set) var renders: [[CmuxToastShown]] = []
    private weak var center: CmuxToastCenter?
    func show(_ toasts: [CmuxToastShown], in window: NSWindow, center: CmuxToastCenter) {
        renders.append(toasts)
        self.center = center
    }

    func neverShowNewest() {
        guard let serial = renders.last?.last?.serial else { return }
        center?.personChoseNeverShow(serial: serial)
    }
}
