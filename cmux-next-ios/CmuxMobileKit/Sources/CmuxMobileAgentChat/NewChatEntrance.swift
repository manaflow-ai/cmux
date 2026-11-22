#if os(iOS)
import CmuxMobileDesign
import QuartzCore
import SwiftUI
import UIKit

/// Leo, 2026-11-22: "claude code has such a nice animation on startup... it's so smooth and
/// nice... I WANT US TO HAVE SHIT LIKE THAT TOO."
///
/// A new chat's greeting (the agent's mark, "What should Claude do?", where it runs) and its
/// composer settle in on a spring the first time the chat shows. It is motion only:
/// - every part is laid out, hit-testable and focusable from frame 0 (the composer takes typing
///   while it settles; nothing is delayed, mounted late or blocked on the animation);
/// - the motion lives in `visualEffect` (render only), so no measured frame moves: the
///   transcript's insets, the keyboard pin and the jump button read the resting geometry;
/// - the start pose is held through the first rendered frame and released from the display
///   link's next tick, so the first frame on screen is the start pose, never a frame part way
///   in (hq handbook: animation-releases-before-first-observed-frame.md);
/// - with Reduce Motion every part is drawn at rest, with no motion at all;
/// - it plays once per chat (`AgentChatStore.newChatEntrance`), not on every swipe back.
///
/// The keyboard half of the feel is UIKit's: the composer is pinned to `keyboardLayoutGuide`
/// (`ChatTranscriptController`) and the greeting centers in the room above it, so when a new
/// chat opens focused the composer rides the keyboard up and the greeting re-centers in the same
/// animation, while the entrance settles on top of it.
public enum NewChatEntrance {
    /// The three looks built for the gallery (cmux-next-ios/design/gallery/new-chat-entrance).
    /// `rise` ships; the others stay selectable in DEBUG builds
    /// (`-cmux-mobile-entrance bloom|focus`) for side-by-side captures.
    public enum Style: String, CaseIterable, Sendable {
        /// Each part rises 10-14 pt and fades in, 50 ms apart, on one soft spring; the composer
        /// comes up from under the fold with them. Calm, quick, reads top to bottom.
        case rise
        /// The mark grows from 55% on a lively spring, then the words follow it in.
        case bloom
        /// Out of focus to sharp: the greeting sharpens from a blur at 106% scale.
        case focus

        /// The look this build plays.
        @MainActor public static var current: Style {
            #if DEBUG
            if let name = UserDefaults.standard.string(forKey: "cmux-mobile-entrance"), let style = Style(rawValue: name) {
                return style
            }
            #endif
            return .rise
        }
    }

    /// The parts, in the order they arrive.
    public enum Part: Int, Sendable {
        case mark, title, detail, composer
    }

    /// Which parts of one chat's entrance have played.
    struct Played {
        var greeting = false
        var composer = false
    }

    /// Where a part starts (unsettled) or rests (settled).
    struct Pose: Equatable, Sendable {
        var opacity: Double = 1
        var y: CGFloat = 0
        var scale: CGFloat = 1
        var blur: CGFloat = 0

        static let rest = Pose()
    }

    static func pose(_ style: Style, _ part: Part, settled: Bool) -> Pose {
        guard !settled else { return .rest }
        switch (style, part) {
        case (.rise, .mark): return Pose(opacity: 0, y: 14, scale: 0.9)
        case (.rise, .title): return Pose(opacity: 0, y: 12)
        case (.rise, .detail): return Pose(opacity: 0, y: 10)
        case (.bloom, .mark): return Pose(opacity: 0, scale: 0.55)
        case (.bloom, .title), (.bloom, .detail): return Pose(opacity: 0, y: 6)
        case (.focus, .mark), (.focus, .title), (.focus, .detail): return Pose(opacity: 0, scale: 1.06, blur: 10)
        case (_, .composer): return Pose(opacity: 0, y: 24)
        }
    }

    /// Each part's spring and its offset from the start.
    static func animation(_ style: Style, _ part: Part) -> Animation {
        switch (style, part) {
        case (.rise, _):
            let delay = [0.0, 0.05, 0.10, 0.04][part.rawValue]
            return .spring(response: 0.5, dampingFraction: 0.84).delay(delay)
        case (.bloom, .mark):
            return .spring(response: 0.55, dampingFraction: 0.6)
        case (.bloom, _):
            let delay = [0.0, 0.12, 0.17, 0.08][part.rawValue]
            return .spring(response: 0.5, dampingFraction: 0.86).delay(delay)
        case (.focus, _):
            let delay = [0.0, 0.03, 0.06, 0.05][part.rawValue]
            return .spring(response: 0.6, dampingFraction: 0.9).delay(delay)
        }
    }
}

extension View {
    /// Draws this part of the new-chat entrance at its start pose until `settled`, then springs
    /// it to rest. Render only: layout, hit testing and focus are the resting view's throughout.
    func newChatEntrance(_ part: NewChatEntrance.Part, style: NewChatEntrance.Style, settled: Bool) -> some View {
        let pose = NewChatEntrance.pose(style, part, settled: settled)
        return visualEffect { content, _ in
            content
                .scaleEffect(pose.scale)
                .offset(y: pose.y)
                .blur(radius: pose.blur)
                .opacity(pose.opacity)
        }
        .animation(NewChatEntrance.animation(style, part).unlessReduceMotion, value: settled)
    }

    /// Sets `settled` once the view's first frame has been on screen: the next display link tick
    /// after it appears (never from `onAppear` itself, whose frame is not drawn yet). Cancelled if
    /// the view goes before that.
    func releasesNewChatEntrance(_ settled: Binding<Bool>, then played: @escaping @MainActor () -> Void = {}) -> some View {
        modifier(EntranceRelease(settled: settled, played: played))
    }
}

private struct EntranceRelease: ViewModifier {
    @Binding var settled: Bool
    let played: @MainActor () -> Void
    @State private var tick = NextFrameTick()

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard !settled else { return }
                tick.schedule {
                    settled = true
                    played()
                }
            }
            .onDisappear { tick.cancel() }
    }
}

/// One display link callback, after the frame being built now has been committed.
@MainActor
final class NextFrameTick {
    private var link: CADisplayLink?
    private var action: (@MainActor () -> Void)?

    func schedule(_ action: @escaping @MainActor () -> Void) {
        cancel()
        self.action = action
        let link = CADisplayLink(target: Target(self), selector: #selector(Target.fire))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func cancel() {
        link?.invalidate()
        link = nil
        action = nil
    }

    fileprivate func fired() {
        // The link cannot fire until the main thread is free, which is after the frame built
        // with the start pose has been committed: the first tick is after that frame.
        guard let action else { return }
        cancel()
        action()
    }

    /// The link retains its target; the target holds the tick weakly.
    /// Main actor: the link is added to the main run loop, so it fires there.
    @MainActor private final class Target: NSObject {
        weak var owner: NextFrameTick?
        init(_ owner: NextFrameTick) { self.owner = owner }
        @objc func fire() { owner?.fired() }
    }
}
#endif
