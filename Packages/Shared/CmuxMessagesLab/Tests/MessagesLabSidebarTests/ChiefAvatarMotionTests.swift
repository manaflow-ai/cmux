import AppKit
import Testing
@testable import MessagesLabSidebar

/// Leo 2026-11-01: "i also want them animated like how chatgpt animates their dots". A Chief's own
/// avatar in the list and the pinned grid loops (slow at idle, livelier while it works) as one Core
/// Animation keyframe loop, and stops under each of its stop conditions: Reduce Motion, the host's
/// gate, the app inactive or the window off screen, and the row going back to the pool.
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
                entry("maya", "Maya", nil, .idle, false),  // no avatar of its own: never moves
                entry("noah", "Noah", .monogram("NO"), nil, false),
            ]
            window.contentView = view
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

        func loop(_ id: String) -> CAKeyframeAnimation? {
            avatar(id)?.animation(forKey: SidebarAvatarMotion.animationKey) as? CAKeyframeAnimation
        }
    }

    init() {
        CmuxSidebarView.reduceMotionOverride = false
    }

    private func reset() {
        CmuxSidebarView.reduceMotionOverride = nil
    }

    @Test func aChiefsAvatarLoopsSlowAtIdleAndFasterWhileItWorks() throws {
        defer { reset() }
        let f = Fixture()
        let idle = try #require(f.loop("scout"), "a row's Chief avatar loops")
        #expect(idle.keyPath == "transform.translation.y")
        #expect(idle.duration == 3.2 && idle.repeatCount == .infinity)
        #expect(try #require(f.loop("chief")).duration == 3.2, "a pinned tile's avatar loops too")
        #expect(f.loop("maya") == nil, "a conversation without its own avatar stands still")
        #expect(f.loop("noah") == nil, "no motion asked: stands still")

        f.set("scout", .working)
        let working = try #require(f.loop("scout"))
        #expect(working.duration == 0.9)
        let depth = { (a: CAKeyframeAnimation) in (a.values as? [NSNumber] ?? []).map(\.doubleValue).map(abs).max() ?? 0 }
        #expect(depth(working) > depth(idle), "working moves further, not only faster")

        // A reload that keeps the mode keeps the running loop (no restart, no jump).
        let running = f.avatar("scout")?.animation(forKey: SidebarAvatarMotion.animationKey)
        f.show()
        f.controller.tile(force: true)
        #expect(f.avatar("scout")?.animation(forKey: SidebarAvatarMotion.animationKey) === running)
    }

    @Test func reduceMotionAndTheHostsGateStopEveryLoop() throws {
        defer { reset() }
        let f = Fixture()
        #expect(f.loop("scout") != nil)
        CmuxSidebarView.reduceMotionOverride = true
        #expect(f.loop("scout") == nil && f.loop("chief") == nil, "Reduce Motion stops them at once")
        CmuxSidebarView.reduceMotionOverride = false
        #expect(f.loop("scout") != nil, "and they start again")

        var homeLoops = false
        f.view.avatarLoopGate = { homeLoops }
        NotificationCenter.default.post(name: CmuxSidebarView.reduceMotionDidChange, object: nil)
        #expect(f.loop("scout") == nil, "Home's motion switch, calm mode or speed off stop them")
        homeLoops = true
        NotificationCenter.default.post(name: CmuxSidebarView.reduceMotionDidChange, object: nil)
        #expect(f.loop("scout") != nil)
    }

    @Test func anInactiveAppOrAHiddenWindowStopsEveryLoop() throws {
        defer { reset() }
        let f = Fixture()
        #expect(f.loop("scout") != nil)
        // The window resigns key: the app went inactive, another window took the keyboard, or it
        // was minimized or hidden. The list's own key tracking stops every loop.
        f.controller.setWindowActive(false)
        #expect(f.loop("scout") == nil && f.loop("chief") == nil)
        f.controller.setWindowActive(true)
        #expect(f.loop("scout") != nil, "and they start again when it is key")

        // Unpinned, the real check: this offscreen test window is not on screen, so nothing loops.
        f.controller.avatarMotion.onScreenPin = nil
        f.controller.setWindowActive(false)
        f.controller.setWindowActive(true)
        #expect(f.loop("scout") == nil, "a window that is not on screen never loops")
    }

    @Test func aRowBackInThePoolStopsAndStillStyleNeverStarts() throws {
        defer { reset() }
        let f = Fixture()
        let avatar = try #require(f.avatar("scout"))
        #expect(avatar.animation(forKey: SidebarAvatarMotion.animationKey) != nil)
        f.entries.removeAll { $0.id == "scout" }
        f.show()
        f.controller.tile(force: true)
        #expect(avatar.animation(forKey: SidebarAvatarMotion.animationKey) == nil, "a pooled avatar never loops")

        f.view.avatarMotionStyle = .still
        f.set("chief", .working)
        #expect(f.loop("chief") == nil)
    }

    @Test func aStyleChangeRestylesEveryAvatarAtOnce() throws {
        defer { reset() }
        let f = Fixture()
        #expect(try #require(f.loop("scout")).keyPath == "transform.translation.y")
        f.view.avatarMotionStyle = .breathe  // no data change, no reload
        #expect(try #require(f.loop("scout")).keyPath == "transform.scale")
        #expect(try #require(f.loop("chief")).keyPath == "transform.scale", "the pinned tile too")
        f.view.avatarMotionStyle = .still
        #expect(f.loop("scout") == nil && f.loop("chief") == nil)
    }

    @Test func everyStyleLoopsAroundItsRestAndTwoChiefsDoNotMoveInStep() {
        for style in CmuxSidebarAvatarMotionStyle.allCases where style != .still {
            for mode in [SidebarAvatarMotion.Mode.idle, .working] {
                let loop = SidebarAvatarMotion.animation(style, mode: mode, seed: "chief")
                let values = (loop.values as? [NSNumber] ?? []).map(\.doubleValue)
                #expect(abs((values.first ?? 0) - (values.last ?? 1)) < 1e-9, "\(style) \(mode) closes its loop (no jump at the wrap)")
                #expect(values.count == 49)
            }
        }
        let a = SidebarAvatarMotion.animation(.float, mode: .idle, seed: "agent_mux")
        let b = SidebarAvatarMotion.animation(.float, mode: .idle, seed: "agent_scout01")
        #expect(a.timeOffset != b.timeOffset)
    }
}
