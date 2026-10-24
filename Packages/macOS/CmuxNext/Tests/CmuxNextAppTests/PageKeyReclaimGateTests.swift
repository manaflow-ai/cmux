import AppKit
import CmuxNextFocus
import Testing

/// Hang B (macOS matrix fuzz, macOS 15.7.7 seed 21): a 10 s main-thread hang inside `makeKeyWindow`
/// from `FocusEffectApplier.reclaimKeyFromPageWindow`. Two windows that take the keys back from each
/// other on every key change ping-pong forever without a gate; with it the cmux window reclaims at most
/// once per focus apply, never from inside its own reclaim, never while hidden or while a menu tracks.
@MainActor @Suite(.serialized) struct PageKeyReclaimGateTests {
    /// A cmux window and a page window: each key change of either one runs a focus apply that wants the
    /// keys back for the cmux window, as the focus model does on `didBecomeKey`.
    final class PingPong {
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        let page = NSWindow(contentRect: CGRect(x: 150, y: 150, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        var gate = PageKeyReclaimGate()
        var keyChanges = 0
        var observers: [NSObjectProtocol] = []

        init() {
            _ = NSApplication.shared
            for w in [window, page] { w.isReleasedWhenClosed = false }
            window.orderFront(nil)
            page.orderFront(nil)
            // The page takes the keys back whenever the cmux window gets them (Chromium's SetFocus).
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: nil) { [unowned self] _ in
                MainActor.assumeIsolated { // main-proof: posted synchronously by makeKey on the main thread
                    self.keyChanges += 1
                    guard self.keyChanges < 50 else { return }
                    self.page.makeKey()
                }
            })
            // Every key change runs a focus apply that wants the keys for the cmux window.
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: page, queue: nil) { [unowned self] _ in
                MainActor.assumeIsolated { // main-proof: posted synchronously by makeKey on the main thread
                    self.keyChanges += 1
                    guard self.keyChanges < 50 else { return }
                    self.focusApply()
                }
            })
        }

        func focusApply(menuIsTracking: Bool = false) {
            gate.beginApply()
            _ = gate.reclaim(windowIsShown: window.isVisible && !window.isMiniaturized, menuIsTracking: menuIsTracking) { window.makeKey() }
        }

        func close() {
            observers.forEach(NotificationCenter.default.removeObserver)
            page.close()
            window.close()
        }
    }

    @Test func twoWindowsTakingTheKeysFromEachOtherDoNotPingPong() {
        let pair = PingPong()
        defer { pair.close() }
        pair.page.makeKey()
        #expect(pair.keyChanges < 50, "the windows took the keys from each other \(pair.keyChanges) times")
        #expect(pair.gate.reclaims <= pair.gate.apply, "at most one reclaim per focus apply: \(pair.gate.reclaims) for \(pair.gate.apply)")
    }

    @Test func noReclaimForAHiddenWindowOrWhileAMenuTracks() {
        var gate = PageKeyReclaimGate()
        var made = 0
        gate.beginApply()
        #expect(!gate.reclaim(windowIsShown: false, menuIsTracking: false) { made += 1 })
        #expect(!gate.reclaim(windowIsShown: true, menuIsTracking: true) { made += 1 })
        #expect(gate.reclaim(windowIsShown: true, menuIsTracking: false) { made += 1 })
        #expect(!gate.reclaim(windowIsShown: true, menuIsTracking: false) { made += 1 }, "one per focus apply")
        gate.beginApply()
        #expect(gate.reclaim(windowIsShown: true, menuIsTracking: false) { made += 1 })
        #expect(made == 2)
    }
}
