import AppKit
import CmuxSettings
import Testing
@testable import CmuxShortcuts

@MainActor
@Suite("ShortcutRouter lifecycle")
struct ShortcutRouterTests {
    /// A controllable host fake recording the calls the router makes and driving
    /// the dispatch result.
    private final class HostFake: ShortcutRoutingHost {
        var keyWindow: NSWindow?
        var activeWindow: NSWindow?
        var chordWindowNumberValue: Int?
        var synchronizeResult = true
        var recorderActive = false
        var dispatchResult = false
        var snapshot = ShortcutEventFocusSnapshot(
            browserFocused: false,
            markdownFocused: false,
            rightSidebarFocused: false,
            shortcutContext: ShortcutContext()
        )

        var popupDispatchResult = false

        private(set) var resolveCount = 0
        private(set) var dispatchCount = 0
        private(set) var popupDispatchCount = 0
        private(set) var clearLiveFocusCacheCount = 0
        private(set) var lastPopupWindow: NSWindow?

        var shortcutRoutingKeyWindow: NSWindow? { keyWindow }
        var shortcutRoutingActiveWindow: NSWindow? { activeWindow }
        func chordWindowNumber(for event: NSEvent) -> Int? { chordWindowNumberValue }
        func synchronizeRoutingContext(for event: NSEvent) -> Bool { synchronizeResult }
        var isAnyShortcutRecorderActive: Bool { recorderActive }
        func resolveFocusSnapshot(for event: NSEvent) -> ShortcutEventFocusSnapshot {
            resolveCount += 1
            return snapshot
        }
        func dispatchConfiguredShortcut(event: NSEvent) -> Bool {
            dispatchCount += 1
            return dispatchResult
        }
        func dispatchPopupCloseShortcut(event: NSEvent, popupWindow: NSWindow) -> Bool {
            popupDispatchCount += 1
            lastPopupWindow = popupWindow
            return popupDispatchResult
        }
        func clearLiveFocusCache(for event: NSEvent) {
            clearLiveFocusCacheCount += 1
        }
    }

    private final class ChordFake: ShortcutChordControlling {
        private(set) var clearCount = 0
        private(set) var prepareCount = 0
        private(set) var clearActiveCount = 0
        private(set) var lastPrepareWindowNumber: Int??

        func clear() { clearCount += 1 }
        func prepareForEvent(windowNumber: Int?) {
            prepareCount += 1
            lastPrepareWindowNumber = windowNumber
        }
        func clearActivePrefixForCurrentEvent() { clearActiveCount += 1 }
    }

    private func keyDownEvent() -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "a",
            charactersIgnoringModifiers: "a",
            isARepeat: false,
            keyCode: 0
        )!
    }

    private func flagsChangedEvent() -> NSEvent {
        NSEvent.keyEvent(
            with: .flagsChanged,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 55
        )!
    }

    @Test("non-keyDown clears the chord and does not dispatch")
    func nonKeyDownClearsChord() {
        let host = HostFake()
        let chord = ChordFake()
        let router = ShortcutRouter(host: host, chord: chord)

        let consumed = router.handle(event: flagsChangedEvent())

        #expect(consumed == false)
        #expect(chord.clearCount == 1)
        #expect(host.dispatchCount == 0)
    }

    @Test("an armed recorder stands down before dispatch")
    func recorderStandsDown() {
        let host = HostFake()
        host.recorderActive = true
        let chord = ChordFake()
        let router = ShortcutRouter(host: host, chord: chord)

        let consumed = router.handle(event: keyDownEvent())

        #expect(consumed == false)
        #expect(chord.clearCount == 1)
        #expect(host.dispatchCount == 0)
    }

    @Test("keyDown prepares the chord, dispatches, then clears the prefix")
    func dispatchLifecycle() {
        let host = HostFake()
        host.chordWindowNumberValue = 7
        host.dispatchResult = true
        let chord = ChordFake()
        let router = ShortcutRouter(host: host, chord: chord)

        let consumed = router.handle(event: keyDownEvent())

        #expect(consumed == true)
        #expect(chord.prepareCount == 1)
        #expect(chord.lastPrepareWindowNumber == .some(.some(7)))
        #expect(host.dispatchCount == 1)
        #expect(chord.clearActiveCount == 1)
    }

    @Test("focus snapshot resolves once per event then caches")
    func focusSnapshotCachesPerEvent() {
        let host = HostFake()
        let chord = ChordFake()
        let router = ShortcutRouter(host: host, chord: chord)
        let event = keyDownEvent()

        _ = router.focusSnapshot(for: event)
        _ = router.focusSnapshot(for: event)
        #expect(host.resolveCount == 1)

        router.clearFocusSnapshotCache(for: event)
        _ = router.focusSnapshot(for: event)
        #expect(host.resolveCount == 2)
    }

    @Test("resetFocusSnapshotCache forces re-resolution")
    func resetForcesReresolution() {
        let host = HostFake()
        let chord = ChordFake()
        let router = ShortcutRouter(host: host, chord: chord)
        let event = keyDownEvent()

        _ = router.focusSnapshot(for: event)
        router.resetFocusSnapshotCache()
        _ = router.focusSnapshot(for: event)
        #expect(host.resolveCount == 2)
    }

    @Test("handle clears the per-event focus cache in its defer")
    func handleClearsFocusCache() {
        let host = HostFake()
        let chord = ChordFake()
        let router = ShortcutRouter(host: host, chord: chord)
        let event = keyDownEvent()

        // Populate the cache, then route the same event: the defer clears it, so a
        // later read re-resolves.
        _ = router.focusSnapshot(for: event)
        #expect(host.resolveCount == 1)
        _ = router.handle(event: event)
        _ = router.focusSnapshot(for: event)
        #expect(host.resolveCount == 2)
    }

    @Test("handle clears the host's live focus cache in its defer")
    func handleClearsLiveFocusCache() {
        let host = HostFake()
        let chord = ChordFake()
        let router = ShortcutRouter(host: host, chord: chord)

        _ = router.handle(event: keyDownEvent())

        #expect(host.clearLiveFocusCacheCount == 1)
    }

    @Test("popup-close routes through the shared lifecycle to the popup dispatch")
    func popupCloseLifecycle() {
        let host = HostFake()
        host.chordWindowNumberValue = 3
        host.popupDispatchResult = true
        let chord = ChordFake()
        let router = ShortcutRouter(host: host, chord: chord)
        let popup = NSWindow()

        let consumed = router.handle(popupCloseEvent: keyDownEvent(), popupWindow: popup)

        #expect(consumed == true)
        #expect(chord.prepareCount == 1)
        #expect(chord.lastPrepareWindowNumber == .some(.some(3)))
        #expect(host.popupDispatchCount == 1)
        #expect(host.dispatchCount == 0)
        #expect(host.lastPopupWindow === popup)
        #expect(chord.clearActiveCount == 1)
        #expect(host.clearLiveFocusCacheCount == 1)
    }

    @Test("popup-close stands down for a non-keyDown event without dispatching")
    func popupCloseNonKeyDownStandsDown() {
        let host = HostFake()
        let chord = ChordFake()
        let router = ShortcutRouter(host: host, chord: chord)

        let consumed = router.handle(popupCloseEvent: flagsChangedEvent(), popupWindow: NSWindow())

        #expect(consumed == false)
        #expect(chord.clearCount == 1)
        #expect(host.popupDispatchCount == 0)
    }

    @Test("popup-close stands down for an armed recorder without dispatching")
    func popupCloseRecorderStandsDown() {
        let host = HostFake()
        host.recorderActive = true
        let chord = ChordFake()
        let router = ShortcutRouter(host: host, chord: chord)

        let consumed = router.handle(popupCloseEvent: keyDownEvent(), popupWindow: NSWindow())

        #expect(consumed == false)
        #expect(chord.clearCount == 1)
        #expect(host.popupDispatchCount == 0)
    }
}
