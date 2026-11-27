import AppKit
@testable import CmuxNextFocusUI
import Testing

/// Holding Cmd, Ctrl or Option fades the hint chips in, and a release fades them out;
/// they never pop (u4457: "holding cmd or ctrl or opt needs to animate in the hints").
@MainActor @Suite
struct ShortcutHintOverlayFadeTests {
    @MainActor
    private final class RecordingFader: ShortcutHintChipFading {
        var fadedIn: [[NSView]] = []
        var alphaAtFadeIn: [CGFloat] = []
        var fadedOut: [[NSView]] = []
        var pending: [@MainActor @Sendable () -> Void] = []

        func fadeIn(_ chips: [NSView], in overlay: NSView) {
            fadedIn.append(chips)
            alphaAtFadeIn += chips.map(\.alphaValue)
        }

        func fadeOut(_ chips: [NSView], in overlay: NSView, completion: @escaping @MainActor @Sendable () -> Void) {
            fadedOut.append(chips)
            pending.append(completion)
        }
    }

    private static func hints(_ count: Int) -> [ShortcutHintOverlayView.Hint] {
        (0..<count).map { .init(text: "⌘\($0 + 1)", rect: CGRect(x: 0, y: CGFloat($0) * 30, width: 200, height: 24)) }
    }

    @Test func aHoldFadesTheChipsInFromClear() {
        let fader = RecordingFader()
        let overlay = ShortcutHintOverlayView(fader: fader)
        overlay.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
        overlay.hints = Self.hints(3)
        #expect(fader.fadedIn.flatMap { $0 }.count == 3, "chips popped in without a fade")
        #expect(fader.alphaAtFadeIn.allSatisfy { $0 == 0 }, "chips start visible: \(fader.alphaAtFadeIn)")
    }

    @Test func aReleaseFadesTheChipsOutBeforeRemovingThem() throws {
        let fader = RecordingFader()
        let overlay = ShortcutHintOverlayView(fader: fader)
        overlay.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
        overlay.hints = Self.hints(2)
        let shown = overlay.subviews.count
        try #require(shown == 2)
        overlay.hints = []
        #expect(fader.fadedOut.flatMap { $0 }.count == 2, "chips vanished without a fade")
        #expect(overlay.subviews.count == 2, "chips were removed before their fade ended")
        for done in fader.pending { done() }
        #expect(overlay.subviews.isEmpty, "faded chips stayed in the overlay")
    }

    /// A refresh while held (geometry, a new binding) moves the chips it keeps: no second fade-in.
    @Test func aRefreshWhileHeldDoesNotFadeAgain() {
        let fader = RecordingFader()
        let overlay = ShortcutHintOverlayView(fader: fader)
        overlay.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
        overlay.hints = Self.hints(2)
        var moved = Self.hints(2)
        moved[0].rect.origin.y += 5
        overlay.hints = moved
        #expect(fader.fadedIn.flatMap { $0 }.count == 2)
        #expect(fader.fadedOut.isEmpty)
    }
}
