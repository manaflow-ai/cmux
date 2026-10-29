import AppKit
import CmuxNextBrowserImport
@testable import CmuxNextApp
import CmuxNextWakeups
import Testing

/// A copied password's clear is a `background` ``MainDeadline`` (recipe R-timer): a side
/// effect nobody watches, which still runs with no window on screen, and leaves a later copy alone.
@MainActor
struct ConcealedPasteboardDeadlineTests {
    @MainActor private final class FakePasteboard: PasswordPasteboard {
        private(set) var changeCount = 0
        private(set) var text: String?

        func write(_ text: String, markers: [NSPasteboard.PasteboardType]) {
            changeCount += 1
            self.text = text
        }

        func clearContents() {
            changeCount += 1
            text = nil
        }
    }

    private static func pasteboard(_ fake: FakePasteboard) -> ConcealedPasteboard {
        ConcealedPasteboard(pasteboard: fake, deadlines: MainDeadlineScheduler(work: MainWorkScheduler(budget: MainFrameBudget())),
                            clearAfter: .milliseconds(20))
    }

    @Test func theDeadlineClearsTheCopiedPassword() async {
        let fake = FakePasteboard()
        let pasteboard = Self.pasteboard(fake)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            pasteboard.onDeadline = { done.resume() }
            pasteboard.write(SecretBytes(copying: Array("throwaway-secret".utf8)))
            #expect(fake.text == "throwaway-secret")
        }
        #expect(fake.text == nil)
    }

    @Test func aLaterCopyStaysOnThePasteboard() async {
        let fake = FakePasteboard()
        let pasteboard = Self.pasteboard(fake)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            pasteboard.onDeadline = { done.resume() }
            pasteboard.write(SecretBytes(copying: Array("throwaway-secret".utf8)))
            fake.write("something else", markers: [])
        }
        #expect(fake.text == "something else")
    }
}
