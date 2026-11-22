import AppKit
import Testing
@testable import CmuxNextSidebar

@MainActor private final class Counter {
    var value = 0
}

/// A profile dot's VoiceOver press runs its main-actor handler on main;
/// called from another thread it refuses instead of trapping in
/// `MainActor.assumeIsolated` (plans/cmux-next/crash-elimination.md, P1b).
@MainActor @Suite struct ProfileDotElementThreadTests {
    @Test func pressOnMainRunsTheHandler() {
        let presses = Counter()
        let element = ProfileDotElement(label: "Work", frame: .zero, parent: NSView()) { presses.value += 1 }
        #expect(element.accessibilityPerformPress())
        #expect(presses.value == 1)
    }

    @Test func pressOffMainRefusesWithoutRunningTheHandler() async {
        let presses = Counter()
        let element = ProfileDotElement(label: "Work", frame: .zero, parent: NSView()) { presses.value += 1 }
        nonisolated(unsafe) let unsafeElement = element
        let handled = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            Thread.detachNewThread { done.resume(returning: unsafeElement.accessibilityPerformPress()) }
        }
        #expect(!handled)
        #expect(presses.value == 0)
    }
}
