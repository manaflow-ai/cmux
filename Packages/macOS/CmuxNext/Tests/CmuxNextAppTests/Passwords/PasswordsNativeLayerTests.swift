import AppKit
@testable import CmuxNextApp
import CmuxNextBrowserImport
import Foundation
import Testing

/// The native layer of the Passwords page: the concealed pasteboard (types, and clearing on its
/// deadline only when nothing else was copied) and the browser profile delete sheet's text.
@MainActor @Suite(.serialized) struct PasswordsNativeLayerTests {
    /// The pasteboard as the test sees it (no pasteboard server on the build workers).
    final class PasteboardFake: PasswordPasteboard {
        private(set) var changeCount = 0
        private(set) var text: String?
        private(set) var markers: [NSPasteboard.PasteboardType] = []
        func write(_ text: String, markers: [NSPasteboard.PasteboardType]) {
            changeCount += 1
            self.text = text
            self.markers = markers
        }
        func clearContents() {
            changeCount += 1
            text = nil
            markers = []
        }
    }

    @Test func aCopiedPasswordIsConcealedTransientAndClearedOnItsDeadline() async throws {
        let pasteboard = PasteboardFake()
        let clock = ManualClock()
        let concealed = ConcealedPasteboard(pasteboard: pasteboard, clock: clock, clearAfter: .seconds(90))
        let (deadlines, signal) = AsyncStream.makeStream(of: Void.self)
        concealed.onDeadline = { signal.yield() }
        var iterator = deadlines.makeAsyncIterator()

        concealed.write(SecretBytes(copying: Array("hunter2".utf8)))
        #expect(pasteboard.markers == [ConcealedPasteboard.concealedType, ConcealedPasteboard.transientType])
        #expect(pasteboard.text == "hunter2")
        await clock.sleepers()
        clock.advance(by: .seconds(89))
        #expect(pasteboard.text == "hunter2", "not before the deadline")
        clock.advance(by: .seconds(1))
        #expect(await iterator.next() != nil)
        #expect(pasteboard.text == nil)

        // Something else copied meanwhile: the deadline leaves it alone.
        concealed.write(SecretBytes(copying: Array("hunter3".utf8)))
        pasteboard.write("other", markers: [])
        await clock.sleepers()
        clock.advance(by: .seconds(90))
        #expect(await iterator.next() != nil)
        #expect(pasteboard.text == "other")
    }

    @Test func theProfileDeleteSheetNamesWhatGoesWithTheProfile() {
        let known = BrowserProfileDeletePrompt.body(PasswordCounts(passwords: 12, passkeys: 2))
        #expect(known.contains("12") && known.contains("2"))
        #expect(known.contains(PasswordStrings.deleteProfileBody))
        let unknown = BrowserProfileDeletePrompt.body(PasswordCounts(passwords: nil, passkeys: nil))
        #expect(unknown.contains(PasswordStrings.deleteProfilePasswordsUnknown))
        #expect(unknown.contains(PasswordStrings.deleteProfilePasskeysUnknown))
        let mixed = BrowserProfileDeletePrompt.body(PasswordCounts(passwords: nil, passkeys: 3))
        #expect(mixed.contains(PasswordStrings.deleteProfilePasswordsUnknown) && mixed.contains(PasswordStrings.deleteProfilePasskeys(3)))
    }
}
