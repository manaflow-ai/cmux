import AppKit

/// cmux: a Chief's avatar in the list and the pinned grid shows what its Chief is doing, one distinct
/// animation per state, like the Codex app's pet (Leo 2026-11-03: "don't bounce the circle. i mean
/// like if you ask codex, ... their dot thing has a few different animations for different
/// scenarios"; first asked 2026-11-01: "i also want them animated like how chatgpt animates their
/// dots"; 2026-11-03, relayed by Chief: "per-state animations like the Codex status dot: thinking, tool
/// running, waiting on you, done"). The avatar itself never moves off its place: no bob, bounce or slide.
///
/// The states (``Mode``) and what the default look (``CmuxSidebarAvatarMotionStyle/ring``) draws:
/// - idle: at rest, nothing runs (the idle budget: no CPU or wakeups while nothing changes);
/// - thinking: its turn runs in the model: a short arc runs around the avatar's edge;
/// - tool: its turn runs a tool: a ring of dots turns slowly around the edge;
/// - waiting: it asked the person something (a question or an approval) and waits on them: a still
///   orange ring;
/// - done: its turn ended and the reply is unread: a small green check badge on the lower trailing edge;
/// - failed: a send failed: a thin red ring, still.
/// A change of state plays one short cue (at most 240 ms, `design/motion-and-polish.md`): a turn
/// ending pops the avatar 4 %, a failure gives it a quick shake of a few degrees about its centre, a
/// done badge with no turn seen grows in, and Ring glints once across the face on every change into a
/// rest state.
///
/// Everything runs on the render server: Core Animation loops and cues on the avatar layer and two
/// named sublayers of it (``SidebarAvatarLooks``), no timer, display link or main-thread work per frame.
/// A reload that keeps the state keeps its loop, so a list update adds no animation work.
///
/// Stop conditions (each removes every loop and cue; a still ring of waiting or failed stays, as a
/// static indicator):
/// - the row or tile goes back to the pool (scrolled away, the conversation gone): ``stop(_:)``
///   removes everything, rings included;
/// - Reduce Motion, calm mode, `ui.animationSpeed` off or Home's motion switch off
///   (``CmuxSidebarView/avatarLoopGate``, the host's `Motion.home.animatesLoops`);
/// - the list's window is not key (the app went inactive, or another window took the keyboard), or
///   it is hidden or minimized: the list's own key tracking (`setWindowActive`) re-applies every
///   avatar, so no observer of its own is added;
/// - style Still: no loop, cue or ring.
struct SidebarAvatarMotion {
    /// What a conversation's Chief is doing, as its avatar shows it: nil shows nothing.
    enum Mode: String, Codable, Hashable, Sendable, CaseIterable {
        case idle
        /// Its turn runs in the model (thinking, writing the reply).
        case thinking
        /// Its turn runs a tool.
        case tool
        /// It asked the person something (a question or an approval) and waits on them.
        case waiting
        /// Its turn ended and the reply is unread.
        case done
        /// A message to the Chief failed to send.
        case failed

        /// Its turn is running (thinking or a tool): the only states that loop.
        var isRunning: Bool { self == .thinking || self == .tool }
    }

    /// What one avatar was asked to show, and the look on it (nil: nothing).
    struct Shown: Equatable {
        var mode: Mode
        var seed: String
        var look: Look?
    }

    /// The look on an avatar: a reload asking for the same keeps it, loops included.
    struct Look: Equatable {
        var style: CmuxSidebarAvatarMotionStyle
        var mode: Mode
        /// Loops run (else only the state's still ring shows).
        var moving: Bool
    }

    /// The key every loop is added under (on the avatar or one of its named sublayers).
    static let animationKey = "cmux.avatarMotion"
    /// The key a state change's one-shot cue is added under, on the avatar.
    static let cueKey = "cmux.avatarMotion.cue"

    /// The host's gate for loops (cmux-next: `Motion.home.animatesLoops`); nil: only Reduce Motion decides.
    var gate: (@MainActor () -> Bool)?
    /// The list's motion is on (`SidebarController.animates`); off (the default), only the state's still ring shows.
    var animates = false
    /// How avatars show their state (the host's Debug setting).
    var style = CmuxSidebarAvatarMotionStyle.ring
    /// The list's window is key (the vendored list's key tracking sets it).
    var windowKey = true
    /// Tests' pin for "the window is on screen" (an offscreen test window never is).
    var onScreenPin: Bool?
    /// The state each conversation's avatar last showed, by conversation id: a cue plays on a change
    /// even when the list draws the changed row on another layer. One entry per conversation shown.
    let lastModes = LastModes()

    final class LastModes {
        var byConversation: [String: Mode] = [:]
    }

    /// Whether loops may run in `window` now: the host's gate (Reduce Motion included), the window
    /// is key (so the app is active), shown and not minimized.
    @MainActor func mayRun(in window: NSWindow?) -> Bool {
        guard animates, !CmuxSidebarView.reducesMotion, gate?() ?? true, windowKey else { return false }
        if let onScreenPin { return onScreenPin }
        // Not the occlusion state: the window server reports it after the window becomes key (a launch
        // or an un-minimize would leave the avatar still), and a key window is the frontmost one.
        guard let window, window.isVisible, !window.isMiniaturized else { return false }
        return true
    }

    /// Shows `mode` on `row`'s avatar for conversation `seed` (its id: each avatar's loop starts at
    /// its own phase, so a list of Chiefs doesn't move in lockstep). Keeps a look of the same mode and
    /// style; replaces one that differs; removes it when `mode` is nil. A changed mode of the same
    /// conversation plays its cue while loops may run.
    @MainActor func apply(_ row: SidebarRowLayer, mode: Mode?, seed: String, window: NSWindow?) {
        guard let mode else { return Self.stop(row) }
        let moving = mayRun(in: window)
        let wanted = style == .still ? nil : Look(style: style, mode: mode, moving: moving)
        // What the layer showed, if it is still this conversation's (a layer reused for another starts over).
        let before = row.avatarMotion?.seed == seed ? row.avatarMotion : nil
        row.avatarMotion = Shown(mode: mode, seed: seed, look: wanted)
        if before?.look != wanted || (wanted.map { SidebarAvatarLooks.isMissing($0, on: row.avatar) } ?? false) {
            // A cue already playing ends too when motion stops (Reduce Motion, the window, Still).
            SidebarAvatarLooks.clear(row.avatar, keepCue: wanted?.moving == true)
            if let wanted { SidebarAvatarLooks.show(wanted, on: row.avatar, seed: seed) }
        } else {
            SidebarAvatarLooks.fit(row.avatar)
        }
        let from = lastModes.byConversation.updateValue(mode, forKey: seed)
        if moving, let wanted, let from, from != mode {
            SidebarAvatarLooks.cue(row.avatar, style: wanted.style, from: from, to: mode)
        }
    }

    /// Re-applies what `row`'s avatar last showed (after a gate, app or window change).
    @MainActor func refresh(_ row: SidebarRowLayer, window: NSWindow?) {
        apply(row, mode: row.avatarMotion?.mode, seed: row.avatarMotion?.seed ?? "", window: window)
    }

    /// Removes every loop, cue and ring (the layer goes back to the pool, or its conversation shows nothing).
    @MainActor static func stop(_ row: SidebarRowLayer) {
        SidebarAvatarLooks.clear(row.avatar, keepCue: false)
        row.avatarMotion = nil
    }

    /// Whether anything on `avatar` loops now (the avatar's own loop, the ring's or the glint's).
    static func isLooping(_ avatar: CALayer) -> Bool {
        ([avatar] + (avatar.sublayers ?? []).flatMap { [$0] + ($0.sublayers ?? []) })
            .contains { $0.animation(forKey: animationKey) != nil }
    }

    /// A stable phase in 0..<1 per conversation, so a reload or a scroll back never jumps a loop.
    static func phase(_ seed: String) -> Double {
        Double(seed.unicodeScalars.reduce(UInt32(7)) { ($0 &* 31) &+ $1.value } % 1000) / 1000
    }
}

/// How a Chief's avatar shows its state (Debug Settings > Home > Chief avatar motion; the gallery's
/// variants). None moves the avatar off its place.
public enum CmuxSidebarAvatarMotionStyle: String, Sendable, CaseIterable {
    /// The default. Idle rests, thinking runs an arc around the edge, a tool turns a ring of dots,
    /// waiting and failed draw a still ring (orange, red), done a green check badge; a turn ending pops,
    /// a failure shakes, each change into a rest state glints once.
    case ring
    /// A soft glow behind the avatar: none at idle, a glint sweeping across while thinking, Ring's
    /// dots with the glow while a tool runs, a still glow while waiting (orange) or failed (red), Ring's
    /// badge when done; the same cues as Ring.
    case glow
    /// The avatar turns its head: at rest at idle, a slow rock while thinking; Ring's dots, rings,
    /// badge and cues otherwise.
    case tilt
    /// No motion and no ring.
    case still
}

extension SidebarController {
    /// cmux: re-applies every row's and tile's avatar look (the window's key state changed).
    func refreshAvatarMotion() {
        for l in rowLayers.values + tileLayers { avatarMotion.refresh(l, window: document.window) }
    }
}
