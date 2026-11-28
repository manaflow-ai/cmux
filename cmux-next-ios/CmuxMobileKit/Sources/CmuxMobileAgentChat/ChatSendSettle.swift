import CmuxMobileModel
import Foundation

/// How a sent message settles into the transcript (Leo, 2026-11-15, after trying NEXT on his
/// iPhone: "Tho the animation for sending messages is kinda ass").
///
/// In every motion the bubble is drawn the moment the person sends (the store's prompt shown as
/// sent), the rows above it glide up by its height on the composer's own spring
/// (`.cmuxMobileSmooth`, `spring(duration: 0.35, bounce: 0)`), and the composer clears and
/// shrinks on that same spring, as Messages does. They differ only in what the bubble does on
/// its own way up. Reduce Motion draws the bubble in place with no motion.
public enum ChatSendMotion: String, CaseIterable, Sendable {
    /// A: the bubble rises out of the composer's field, faster than the rows above it, fading in.
    case rise = "A"
    /// B: the bubble fades in and grows from 92 % at its bottom trailing corner as it glides.
    case fade = "B"
    /// C: the bubble rides the rows up from behind the composer, nothing of its own.
    case glide = "C"
    /// The motion before this change: the rows jump to the bottom and the bubble fades in
    /// (a DEBUG comparison only).
    case off

    /// The motion this build uses: ``chosen``, or in DEBUG the one `-cmuxMobile.dev.sendMotion A|B|C|off`
    /// names (`DeveloperOptions.sendMotionKey`).
    public static var current: ChatSendMotion {
        #if DEBUG
        if let raw = UserDefaults.standard.string(forKey: DeveloperOptions.sendMotionKey),
           let picked = allCases.first(where: { $0.rawValue.lowercased() == raw.lowercased() }) {
            return picked
        }
        #endif
        return chosen
    }

    /// The default, picked from the simulator recordings of all three: the bubble comes out of the
    /// field as in Messages, and its fade keeps a solid bubble from showing through the see-through
    /// composer on its way up (C slid it, opaque, under the placeholder).
    public static let chosen: ChatSendMotion = .rise
}

/// The composer's spring as a function of time, so the transcript's rows (a UIKit scroll offset
/// set every display frame) move on exactly the curve SwiftUI moves the composer on.
///
/// `spring(duration: d, bounce: 0)` is critically damped with ω = 2π / d: from rest, the share
/// of the way covered after `t` seconds is 1 − (1 + ωt)·e^(−ωt).
enum ChatSendSpring {
    static let duration: Double = 0.35
    static let omega = 2 * Double.pi / duration

    /// Share of the way covered, 0 at `t` = 0 to 1.
    static func progress(_ t: Double) -> Double {
        guard t > 0 else { return 0 }
        let wt = omega * t
        return min(1, 1 - (1 + wt) * exp(-wt))
    }

    /// Past this the rest is under a quarter point for any travel the transcript makes.
    static let settleTime: Double = 0.6
}

/// One send's settle: what the transcript's following offset still has to travel. The offset is
/// the newest row's resting place less ``remaining(at:)``, so the rows move on the spring while
/// the composer's height (also on it) and the keyboard move the resting place under them.
struct ChatSendSettle {
    /// The rows the send put in (the prompt bubble, its working line).
    var rowIDs: [String]
    var motion: ChatSendMotion
    /// The content height before the rows went in.
    var fromHeight: Double
    /// When the send drew the rows (before their first layout).
    var armedAt: Double = 0
    /// When the glide started (its first layout pass with the rows in), nil until then.
    var start: Double?
    /// The travel at the start: the content's growth, plus any growth while it runs.
    var reach: Double = 0
    /// The content height the glide last accounted for.
    var contentHeight: Double = 0

    /// Starts the glide on the first layout with the rows in: it travels what they added to the
    /// content (the keyboard going down moves the resting place on its own). False when nothing grew.
    mutating func begin(contentHeight: Double, at time: Double) -> Bool {
        let travel = contentHeight - fromHeight
        guard travel > 0.5 else { return false }
        start = time
        reach = travel
        self.contentHeight = contentHeight
        return true
    }

    func progress(at time: Double) -> Double {
        guard let start else { return 0 }
        return ChatSendSpring.progress(time - start)
    }

    /// A row in the glide grew (its measured height, the answer's first words): the rows above
    /// do not jump, the growth joins what the glide has left.
    mutating func contentGrew(to height: Double, at time: Double) {
        let grown = height - contentHeight
        contentHeight = height
        guard abs(grown) > 0.01 else { return }
        let left = max(1 - progress(at: time), 0.05)
        reach = max(0, reach + grown / left)
    }

    func remaining(at time: Double) -> Double { reach * (1 - progress(at: time)) }

    func isDone(at time: Double) -> Bool {
        guard let start else { return false }
        return time - start >= ChatSendSpring.settleTime || remaining(at: time) < 0.25
    }
}

#if DEBUG
/// What the send glide did, newest last (DEBUG): the transcript shows it as the value of a
/// one-point accessibility element, `chat.sendSettle.trace`, which ChatSendMotionUITests attaches,
/// so a fleet recording says why a send glided or did not.
@MainActor
enum ChatSendTrace {
    /// A run that picks a send motion at launch (`-cmuxMobile.dev.sendMotion`, ChatSendMotionUITests)
    /// shows the trace; no other build or test adds its element.
    static let isShown = ProcessInfo.processInfo.arguments.contains("-" + DeveloperOptions.sendMotionKey)
    private(set) static var lines: [String] = []
    static var changed: (() -> Void)?

    static func log(_ line: String) {
        lines.append(line)
        if lines.count > 24 { lines.removeFirst(lines.count - 24) }
        changed?()
    }
}
#endif
