import Foundation

/// Notices a shown streamed page that stopped: no picture after a keyframe
/// was asked for (the decoder lost its state, the lane stopped delivering,
/// the host hung). A still page sends no frames, so silence alone is not a
/// stall: the watchdog asks the Mac for a keyframe, which a working stream
/// always answers, and acts only when that goes unanswered (the 2026-10-24
/// freeze, cmux-next-ios/verify/browser-freeze.md).
///
/// Pure and clocked by the caller; ``StreamedBrowserModel`` feeds it and
/// carries out what ``check(at:)`` returns.
struct BrowserStallWatchdog {
    /// No picture for this long while shown: ask for a keyframe.
    static let idleProbe: Duration = .seconds(10)
    /// Input went to the page and no picture came for this long: ask sooner.
    static let inputProbe: Duration = .seconds(2)
    /// A keyframe asked for and nothing shown this long: the decoder starts over.
    static let restartDecoder: Duration = .seconds(3)
    /// ...and this long: the stream opens again.
    static let reopen: Duration = .seconds(6)

    enum Action: Equatable {
        case none
        case askKeyframe
        case restartDecoder
        case reopen
    }

    /// Since when the stream has been watched (open and shown); nil: not watching.
    private(set) var watchingSince: ContinuousClock.Instant?
    private var lastPicture: ContinuousClock.Instant?
    private var lastInput: ContinuousClock.Instant?
    /// The oldest keyframe request no picture has answered yet.
    private var asked: ContinuousClock.Instant?
    private var restarted = false

    var watching: Bool { watchingSince != nil }

    mutating func start(at now: ContinuousClock.Instant) {
        self = Self()
        watchingSince = now
    }

    mutating func stop() {
        self = Self()
    }

    mutating func pictureShown(at now: ContinuousClock.Instant) {
        lastPicture = now
        asked = nil
        restarted = false
    }

    /// The decoder (or the watchdog itself) asked the Mac for a keyframe.
    mutating func keyframeAsked(at now: ContinuousClock.Instant) {
        guard watching, asked == nil else { return }
        asked = now
    }

    mutating func inputSent(at now: ContinuousClock.Instant) {
        lastInput = now
    }

    mutating func check(at now: ContinuousClock.Instant) -> Action {
        guard let watchingSince else { return .none }
        if let asked {
            let waited = asked.duration(to: now)
            if waited >= Self.reopen {
                return .reopen
            }
            if waited >= Self.restartDecoder, !restarted {
                restarted = true
                return .restartDecoder
            }
            return .none
        }
        let last = lastPicture ?? watchingSince
        let inputUnanswered = lastInput.map { $0 > last && $0.duration(to: now) >= Self.inputProbe } ?? false
        if inputUnanswered || last.duration(to: now) >= Self.idleProbe {
            asked = now
            return .askKeyframe
        }
        return .none
    }
}
