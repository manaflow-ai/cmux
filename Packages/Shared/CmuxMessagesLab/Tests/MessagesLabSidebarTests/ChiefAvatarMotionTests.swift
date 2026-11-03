import AppKit
import Testing
@testable import MessagesLabSidebar

/// Leo 2026-11-03: "don't bounce the circle. i mean like if you ask codex, ... their dot thing has a few
/// different animations for different scenarios". A Chief's own avatar in the list and the pinned grid
/// shows its state, one look per state (idle glints, working runs an arc, waiting and failed draw a still
/// ring), plays a short cue when the state changes, never moves off its place, and stops every loop under
/// each stop condition: Reduce Motion, the host's gate, the app inactive or the window off screen, and the
/// row going back to the pool.
@MainActor
@Suite(.serialized)
struct ChiefAvatarMotionTests {
    @MainActor
    private final class Fixture {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        let view = CmuxSidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 700))
        var entries: [CmuxSidebarEntry]
        var controller: SidebarController { view.controller }

        init() {
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let entry = { (id: String, name: String, avatar: CmuxSidebarEntry.Avatar?, motion: CmuxSidebarEntry.AvatarMotion?, pinned: Bool) in
                CmuxSidebarEntry(id: id, title: name, people: [.init(id: "p-\(id)", name: name, initials: "XX")], preview: "hi",
                                 previewSender: nil, lastAt: now, unreadCount: 0, pinned: pinned, avatar: avatar, avatarMotion: motion)
            }
            entries = [
                entry("chief", "Chief", .monogram("CH"), .idle, true),
                entry("scout", "Scout", .monogram("SC"), .idle, false),
                entry("maya", "Maya", nil, .working, false),  // no avatar of its own: shows nothing
                entry("noah", "Noah", .monogram("NO"), nil, false),
            ]
            window.contentView = view
            view.animates = true  // this suite tests the motion itself (off by default, msg 20105)
            controller.avatarMotion.onScreenPin = true
            controller.setWindowActive(true)  // the host's window is key
            show()
            view.layoutSubtreeIfNeeded()
            controller.view.layoutSubtreeIfNeeded()
            controller.document.layoutSubtreeIfNeeded()
            controller.tile(force: true)
        }

        func show() { view.show(entries, pinned: entries.filter(\.pinned).map(\.id)) }

        func set(_ id: String, _ motion: CmuxSidebarEntry.AvatarMotion?) {
            for i in entries.indices where entries[i].id == id { entries[i].avatarMotion = motion }
            show()
            controller.tile(force: true)
        }

        var layers: [SidebarRowLayer] {
            (controller.document.layer?.sublayers ?? []).compactMap { $0 as? SidebarRowLayer }
        }

        func avatar(_ id: String) -> CALayer? { layers.first { $0.conversationID == id && !$0.isHidden }?.avatar }

        func looping(_ id: String) -> Bool { avatar(id).map(SidebarAvatarMotion.isLooping) ?? false }

        func ring(_ id: String) -> CAShapeLayer? {
            avatar(id)?.sublayers?.first { $0.name == SidebarAvatarLooks.ringName } as? CAShapeLayer
        }

        func glintMove(_ id: String) -> CAKeyframeAnimation? {
            avatar(id)?.sublayers?.first { $0.name == SidebarAvatarLooks.glintName }?.sublayers?.first?
                .animation(forKey: SidebarAvatarMotion.animationKey) as? CAKeyframeAnimation
        }

        func cue(_ id: String) -> CAAnimation? { avatar(id)?.animation(forKey: SidebarAvatarMotion.cueKey) }
    }

    init() {
        CmuxSidebarView.reduceMotionOverride = false
    }

    private func reset() {
        CmuxSidebarView.reduceMotionOverride = nil
    }

    /// No animation anywhere on the avatar moves it off its place (the bounce Leo turned down).
    private func neverTranslates(_ avatar: CALayer) -> Bool {
        let layers = [avatar] + (avatar.sublayers ?? [])
        for layer in layers {
            for key in layer.animationKeys() ?? [] {
                guard let path = (layer.animation(forKey: key) as? CAPropertyAnimation)?.keyPath else { continue }
                if layer === avatar, path.hasPrefix("transform.translation") || path.hasPrefix("position") { return false }
            }
        }
        return true
    }

    @Test func eachStateHasItsOwnLookAndTheAvatarNeverLeavesItsPlace() throws {
        defer { reset() }
        let f = Fixture()
        #expect(f.view.avatarMotionStyle == .ring, "Ring is the default")

        // Idle: a glint sweeps across now and then; no ring.
        let idle = try #require(f.glintMove("scout"), "idle glints")
        #expect(idle.duration == SidebarAvatarLooks.idleGlintPeriod && idle.repeatCount == .infinity)
        #expect(f.ring("scout") == nil)
        #expect(f.glintMove("chief") != nil, "a pinned tile's avatar too")
        #expect(f.avatar("maya").map(SidebarAvatarMotion.isLooping) != true, "a conversation without its own avatar shows nothing")
        #expect(!f.looping("noah"), "no state asked: nothing")

        // Working: an arc turns round the edge.
        f.set("scout", .working)
        let arc = try #require(f.ring("scout"))
        #expect(arc.strokeEnd < 0.5, "an arc, not the whole ring")
        let turn = try #require(arc.animation(forKey: SidebarAvatarMotion.animationKey) as? CABasicAnimation)
        #expect(turn.keyPath == "transform.rotation.z" && turn.duration == SidebarAvatarLooks.arcPeriod)
        #expect(f.glintMove("scout") == nil)

        // A reload that keeps the state keeps the running loop (no restart, no jump).
        f.show()
        f.controller.tile(force: true)
        #expect(f.ring("scout")?.animation(forKey: SidebarAvatarMotion.animationKey) === turn)

        // Waiting: a still accent ring, no loop. Failed: a still red ring.
        f.set("scout", .waiting)
        let waiting = try #require(f.ring("scout"))
        #expect(waiting.strokeEnd == 1 && !f.looping("scout"))
        f.set("scout", .failed)
        let failed = try #require(f.ring("scout"))
        #expect(failed.strokeColor == NSColor.systemRed.cgColor && !f.looping("scout"))

        for style in CmuxSidebarAvatarMotionStyle.allCases {
            f.view.avatarMotionStyle = style
            for mode in [CmuxSidebarEntry.AvatarMotion.idle, .working, .waiting, .failed] {
                f.set("scout", mode)
                #expect(neverTranslates(try #require(f.avatar("scout"))), "\(style) \(mode) moves the avatar off its place")
            }
        }
    }

    @Test func aStateChangePlaysOneShortCue() throws {
        defer { reset() }
        let f = Fixture()
        f.set("scout", .working)
        #expect(f.cue("scout") == nil, "starting work needs no cue: the arc says it")
        f.set("scout", .waiting)
        let pop = try #require(f.cue("scout") as? CAKeyframeAnimation, "a turn ending pops")
        #expect(pop.keyPath == "transform.scale" && pop.duration <= 0.24)
        #expect((pop.values as? [NSNumber] ?? []).map(\.doubleValue).max() ?? 0 <= 1.04)
        f.set("scout", .failed)
        let shake = try #require(f.cue("scout") as? CAKeyframeAnimation, "a failure shakes")
        #expect(shake.keyPath == "transform.rotation.z" && shake.duration <= 0.24)
        #expect(pop.isRemovedOnCompletion && shake.isRemovedOnCompletion, "cues remove themselves")

        // A reload of the same state replays nothing.
        f.avatar("scout")?.removeAnimation(forKey: SidebarAvatarMotion.cueKey)
        f.show()
        f.controller.tile(force: true)
        #expect(f.cue("scout") == nil)

        // Under Reduce Motion a change plays no cue.
        CmuxSidebarView.reduceMotionOverride = true
        f.set("scout", .working)
        f.set("scout", .idle)
        #expect(f.cue("scout") == nil)
    }

    @Test func reduceMotionAndTheHostsGateStopEveryLoopButKeepStillRings() throws {
        defer { reset() }
        let f = Fixture()
        f.set("chief", .working)
        f.set("noah", .failed)
        #expect(f.looping("scout") && f.looping("chief"))
        CmuxSidebarView.reduceMotionOverride = true
        #expect(!f.looping("scout") && !f.looping("chief"), "Reduce Motion stops them at once")
        #expect(f.ring("chief") != nil, "working's arc stands still, so the state still reads")
        CmuxSidebarView.reduceMotionOverride = false
        #expect(f.looping("scout") && f.looping("chief"), "and they start again")

        var homeLoops = false
        f.view.avatarLoopGate = { homeLoops }
        NotificationCenter.default.post(name: CmuxSidebarView.reduceMotionDidChange, object: nil)
        #expect(!f.looping("scout"), "Home's motion switch, calm mode or speed off stop them")
        homeLoops = true
        NotificationCenter.default.post(name: CmuxSidebarView.reduceMotionDidChange, object: nil)
        #expect(f.looping("scout"))
    }

    @Test func anInactiveAppOrAHiddenWindowStopsEveryLoop() throws {
        defer { reset() }
        let f = Fixture()
        f.set("chief", .working)
        #expect(f.looping("scout") && f.looping("chief"))
        // The window resigns key: the app went inactive, another window took the keyboard, or it
        // was minimized or hidden. The list's own key tracking stops every loop.
        f.controller.setWindowActive(false)
        #expect(!f.looping("scout") && !f.looping("chief"))
        f.controller.setWindowActive(true)
        #expect(f.looping("scout"), "and they start again when it is key")

        // Unpinned, the real check: this offscreen test window is not on screen, so nothing loops.
        f.controller.avatarMotion.onScreenPin = nil
        f.controller.setWindowActive(false)
        f.controller.setWindowActive(true)
        #expect(!f.looping("scout"), "a window that is not on screen never loops")
    }

    @Test func aRowBackInThePoolClearsAndStillShowsNothing() throws {
        defer { reset() }
        let f = Fixture()
        f.set("scout", .working)
        let avatar = try #require(f.avatar("scout"))
        #expect(SidebarAvatarMotion.isLooping(avatar))
        f.entries.removeAll { $0.id == "scout" }
        f.show()
        f.controller.tile(force: true)
        #expect(!SidebarAvatarMotion.isLooping(avatar), "a pooled avatar never loops")
        #expect(avatar.sublayers?.contains { $0.name == SidebarAvatarLooks.ringName } != true, "nor keeps a ring")

        f.view.avatarMotionStyle = .still
        f.set("chief", .working)
        #expect(!f.looping("chief") && f.ring("chief") == nil)
    }

    @Test func aStyleChangeRestylesEveryAvatarAtOnce() throws {
        defer { reset() }
        let f = Fixture()
        f.set("scout", .working)
        #expect(f.ring("scout") != nil)
        f.view.avatarMotionStyle = .tilt  // no data change, no reload
        let rock = try #require(f.avatar("scout")?.animation(forKey: SidebarAvatarMotion.animationKey) as? CAKeyframeAnimation)
        #expect(rock.keyPath == "transform.rotation.z" && f.ring("scout") == nil)
        #expect(f.avatar("chief")?.animation(forKey: SidebarAvatarMotion.animationKey) != nil, "the pinned tile too")
        f.view.avatarMotionStyle = .glow
        #expect(try #require(f.avatar("scout")).shadowOpacity > 0 && f.glintMove("scout") != nil)
        f.view.avatarMotionStyle = .still
        #expect(!f.looping("scout") && !f.looping("chief") && f.avatar("scout")?.shadowOpacity == 0)
    }

    @Test func loopsCloseAndTwoChiefsDoNotMoveInStep() throws {
        let a = CALayer(), b = CALayer()
        a.bounds = CGRect(x: 0, y: 0, width: 40, height: 40)
        b.bounds = a.bounds
        let look = SidebarAvatarMotion.Look(style: .tilt, mode: .working, moving: true)
        SidebarAvatarLooks.show(look, on: a, seed: "agent_mux")
        SidebarAvatarLooks.show(look, on: b, seed: "agent_scout01")
        let rockA = try #require(a.animation(forKey: SidebarAvatarMotion.animationKey) as? CAKeyframeAnimation)
        let rockB = try #require(b.animation(forKey: SidebarAvatarMotion.animationKey) as? CAKeyframeAnimation)
        #expect(rockA.timeOffset != rockB.timeOffset)
        let values = (rockA.values as? [NSNumber] ?? []).map(\.doubleValue)
        #expect(values.first == values.last, "no jump at the wrap")
        #expect(values.map(abs).max() ?? 1 <= 4 * .pi / 180 + 1e-9, "a few degrees, no more")
    }
}
