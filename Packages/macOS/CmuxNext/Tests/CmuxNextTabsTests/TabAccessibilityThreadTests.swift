import AppKit
import Testing
@testable import CmuxNextTabs

@MainActor private final class Counter {
    var value = 0
}

/// VoiceOver callbacks on a tab element run the tab's main-actor handlers
/// on main; called from another thread they refuse instead of trapping in
/// `MainActor.assumeIsolated` (plans/cmux-next/crash-elimination.md, P1b).
@MainActor @Suite struct TabAccessibilityThreadTests {
    @Test func pressOnMainRunsTheHandler() {
        let element = TabAccessibilityElement()
        let presses = Counter()
        element.onPress = { presses.value += 1 }
        #expect(element.accessibilityPerformPress())
        #expect(presses.value == 1)
    }

    @Test func pressOffMainRefusesWithoutRunningTheHandler() async {
        let element = TabAccessibilityElement()
        let presses = Counter()
        element.onPress = { presses.value += 1 }
        let handled = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            Thread.detachNewThread { done.resume(returning: element.accessibilityPerformPress()) }
        }
        #expect(!handled)
        #expect(presses.value == 0)
    }

    @Test func customActionsOffMainAreNone() async {
        let element = TabAccessibilityElement()
        element.onClose = {}
        let count = await withCheckedContinuation { (done: CheckedContinuation<Int, Never>) in
            Thread.detachNewThread { done.resume(returning: element.accessibilityCustomActions()?.count ?? 0) }
        }
        #expect(count == 0)
        #expect(element.accessibilityCustomActions()?.count == 1)
    }

    @Test func focusOffMainDoesNotTrap() async {
        let element = TabAccessibilityElement()
        let focused = Counter()
        element.onFocus = { _ in focused.value += 1 }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            Thread.detachNewThread {
                element.setAccessibilityFocused(true)
                DispatchQueue.main.async { done.resume() }
            }
        }
        #expect(focused.value == 0)
        element.setAccessibilityFocused(true)
        #expect(focused.value == 1)
    }
}
