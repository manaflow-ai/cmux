import AppKit
import CmuxHomeCore
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextFeedClient
@testable import CmuxNextHome
import CmuxNextPages
import CmuxNextSettings
import CmuxNextTestSupport
import Foundation
import Observation
import Testing

/// Chief Home's pinned Needs you section (Leo, via his Chief: "a pinned Needs you view in Chief
/// Home, Feed and iPhone listing items waiting on Leo"): the Feed page on `#/needs-you`, sized from
/// the daemon's Needs you view (`feed.view.read {layout: needs_you}`, no second store); it shows
/// only in a Chief's conversation and only while something waits; it sits under the header over the
/// transcript, so showing or hiding it moves no message. It is opt-in (Leo 2026-11-03: "I just
/// wanted to see permission things, period, not a pinned thing by default. Toggle-on, yes"): off by
/// default (`feed.needsYouInChief`), nothing is pinned and the Feed still lists the requests.
@MainActor @Suite(.serialized, .closesItsWindows) struct HomeNeedsYouTests {
    /// The daemon's Needs you view with `ids` waiting; `live` false is a view before the owner answered.
    private static func needsYou(_ ids: [String], live: Bool = true) -> String {
        let entries = ids.map { #"{"id":"\#($0)","item":{"id":"\#($0)","type":"request","kind":"approve","state":"open"}}"# }
        let connection = live ? "connected" : "connecting"
        return #"{"loaded":\#(live),"connection":{"state":"\#(connection)"},"groups":[{"id":"needs_you","entries":[\#(entries.joined(separator: ","))]}]}"#
    }

    /// Lets main-actor tasks run until `condition` holds (bounded).
    private func until(_ condition: () -> Bool) async {
        var tries = 0
        while !condition(), tries < 400 {
            tries += 1
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func itIsTheHeaderAndARowPerRequestUpToThree() {
        #expect(FeedNeedsYouSection.height(waiting: 0) == 0, "nothing waits: hidden")
        // The page's CSS px: the page and the card pad 4 each, the header 24, a row 40.
        #expect(FeedNeedsYouSection.height(waiting: 1) == CGFloat(8 * 2 + 24 + 40))
        #expect(FeedNeedsYouSection.height(waiting: 3) == 160, "three rows fit at 100%")
        #expect(FeedNeedsYouSection.height(waiting: 7) == FeedNeedsYouSection.height(waiting: 3), "the page counts the rest")
        let section = FeedNeedsYouSection(page: NSView())
        section.waiting = 2
        #expect(section.intrinsicContentSize.height == FeedNeedsYouSection.height(waiting: 2))
    }

    /// Review F1 of #37378: the page follows `ui.scale`, so the section is its CSS height times the
    /// page's zoom; at 125% three rows need 200 points, not 160.
    @Test func threeRowsFitAtEveryScale() {
        #expect(FeedNeedsYouSection.height(waiting: 3, zoom: 1.25) == 200)
        let section = FeedNeedsYouSection(page: NSView())
        section.waiting = 3
        section.zoom = 1.25
        #expect(section.intrinsicContentSize.height == 200)
        #expect(section.fittingSize.height == 200)
    }

    /// A `ui.scale` change resizes the pinned section live: the Feed page's zoom change gives the
    /// section its new zoom and the host measures it again.
    @Test func aScaleChangeResizesTheHost() async throws {
        let saved = DesignSettings.shared.uiScale
        defer { DesignSettings.shared.uiScale = saved }
        DesignSettings.shared.uiScale = 1
        let directory = FileManager.default.temporaryDirectory.appending(path: "needs-you-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("<!doctype html><title>Needs you</title>".utf8).write(to: directory.appending(path: "index.html"))
        let descriptor = PageDescriptor(id: "test.needs-you", resource: "needs-you", namespaces: [])
        let page = try #require(PageWebView(descriptor: descriptor, root: directory, routes: []))
        defer { page.close() }

        let daemon = FakeFeedDaemon()
        daemon.reply("feed.view.read", Self.needsYou(["a", "b", "c"]))
        let host = PinHost(), toggle = PinToggle()
        toggle.on = true
        let watch = FeedNeedsYouSection.watch(feed: daemon.client, isEnabled: { toggle.on }, host: host) {
            FeedNeedsYouSection(page: page, zoom: { [weak page] in page?.pageZoom ?? 1 }) { page.onZoomChange = $0 }
        }
        defer { watch.cancel() }
        await until { host.pinnedSection != nil }
        let section = try #require(host.pinnedSection as? FeedNeedsYouSection)
        #expect(section.fittingSize.height == 160)
        let resizes = host.resizes

        DesignSettings.shared.uiScale = 1.25
        await until { host.resizes > resizes }
        #expect(host.resizes > resizes, "a scale change measures the section again")
        #expect(section.zoom == 1.25)
        #expect(section.fittingSize.height == 200, "three rows fit at 125%")
    }

    @Test func itIsOffByDefaultAndTheSettingTurnsItOn() throws {
        #expect(HomeNeedsYouSetting.fallback == false)
        let unset = CmuxConfigSnapshot.parse(.object([:]), validDensities: [], validMetrics: [])
        #expect(unset.homeNeedsYouInChief == false, "unset cmux.json: no pinned card")
        let on = CmuxConfigSnapshot.parse(try JSONValue.parse(Data(#"{"feed":{"needsYouInChief":true}}"#.utf8)),
                                          validDensities: [], validMetrics: [])
        #expect(on.homeNeedsYouInChief == true)
        let row = try #require(SettingsSchema.descriptor(for: HomeNeedsYouSetting.configPath))
        #expect(row.defaultValue == .bool(false), "Settings shows it off by default")
    }

    @Test func offPinsNothingAndOnPinsTheDaemonsRequestsLive() async {
        let daemon = FakeFeedDaemon()
        daemon.reply("feed.view.read", Self.needsYou(["a"]))
        let host = PinHost(), toggle = PinToggle()
        let watch = FeedNeedsYouSection.watch(feed: daemon.client, isEnabled: { toggle.on }, host: host) { FeedNeedsYouSection(page: NSView()) }
        defer { watch.cancel() }
        await until { host.updates > 0 }
        #expect(host.pinnedSection == nil, "off by default: nothing pinned while a request waits")
        #expect(daemon.ops.isEmpty, "off reads nothing")
        toggle.on = true // the app's setting is observable the same way, so turning it on pins at once
        await until { host.pinnedSection != nil }
        #expect((host.pinnedSection as? FeedNeedsYouSection)?.waiting == 1)
        #expect(daemon.calls.last?.params["layout"]?.stringValue == "needs_you")

        // A second request: the same section grows.
        let section = host.pinnedSection
        daemon.reply("feed.view.read", Self.needsYou(["a", "b"]))
        daemon.client.deliver(.init(changed: ["b"]))
        await until { host.resizes > 0 }
        #expect(host.pinnedSection === section)
        #expect((host.pinnedSection as? FeedNeedsYouSection)?.waiting == 2)

        // Before the owner answers (a reconnect), an empty view is not "nothing waits".
        daemon.reply("feed.view.read", Self.needsYou([], live: false))
        let reads = daemon.calls.count
        daemon.client.deliver(.init(changed: nil))
        await until { daemon.calls.count > reads }
        try? await Task.sleep(for: .milliseconds(50)) // the read's decode and its (absent) change
        #expect(host.pinnedSection === section)

        // Answered: nothing waits, the section goes.
        daemon.reply("feed.view.read", Self.needsYou([]))
        daemon.client.deliver(.init(changed: ["a", "b"]))
        await until { host.pinnedSection == nil }
        #expect(host.pinnedSection == nil)

        // Off again: nothing pinned and no more reads.
        daemon.reply("feed.view.read", Self.needsYou(["c"]))
        let updates = host.updates
        toggle.on = false
        await until { host.updates > updates } // the watch saw the setting go off (it unpins, so it updates)
        let after = daemon.calls.count
        daemon.client.deliver(.init(changed: ["c"]))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(daemon.calls.count == after, "off reads nothing")
        #expect(host.pinnedSection == nil)
    }

    @Test func thePinnedSectionSitsUnderTheHeaderAndMovesNoMessage() async throws {
        let source = EmptyChiefSource()
        let id = ConversationID("conv_chief")
        let inbox = try await source.inbox()
        let store = HomeStore(source: source)
        store.start()
        let view = HomeNativeTranscriptView(store: store, conversation: id, me: inbox.me.id)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 800), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { view.stop(); store.stop(); window.close() }
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 800)
        window.contentView = view
        await view.binding.opened()
        view.layoutSubtreeIfNeeded()
        let transcriptFrame = view.transcript.frame
        #expect(view.pinnedSection == nil)

        let section = FeedNeedsYouSection(page: NSView())
        section.waiting = 1
        view.setPinnedSection(section)
        view.layoutSubtreeIfNeeded()
        #expect(view.pinnedSection === section)
        #expect(section.superview === view)
        #expect(section.frame.minY >= view.headerHeight, "under the header: \(section.frame) header \(view.headerHeight)")
        #expect(section.frame.height > 0)
        #expect(section.frame.maxY < view.transcript.fieldTop, "above the message box")
        #expect(view.transcript.frame == transcriptFrame, "the transcript keeps its frame: nothing shifts")
        // The oldest message can still scroll out from under the card (Codex review, #33817).
        #expect(view.transcript.rowsTopClearance >= section.frame.maxY - view.headerHeight)

        view.setPinnedSection(nil)
        view.layoutSubtreeIfNeeded()
        #expect(view.pinnedSection == nil)
        #expect(section.superview == nil)
        #expect(view.transcript.rowsTopClearance == 0)
        #expect(view.transcript.frame == transcriptFrame)
    }

    @Test func theSetupCardFitsAShortPaneAndIsNeverHidden() async throws {
        let source = EmptyChiefSource()
        let id = ConversationID("conv_chief")
        let inbox = try await source.inbox()
        let store = HomeStore(source: source)
        store.start()
        let view = HomeNativeTranscriptView(store: store, conversation: id, me: inbox.me.id)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 420), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { view.stop(); store.stop(); window.close() }
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 420)
        window.contentView = view
        await view.binding.opened()
        let card = NSView()

        view.setSetupCard(card, height: 0)
        view.layoutSubtreeIfNeeded()
        #expect(!card.isHidden && card.frame.height == 1, "unsized, the page stays in the window to measure: \(card.frame)")

        // Taller than the pane: the slot stops above the message box and the page scrolls inside it.
        view.setSetupCard(card, height: 2000)
        view.layoutSubtreeIfNeeded()
        #expect(card.frame.height > 1 && card.frame.height < 2000, "\(card.frame)")
        #expect(card.frame.maxY < view.transcript.fieldTop, "above the message box")

        // Needs you rows taller than the pane: the pinned section gives way, and the card keeps a usable height.
        let pinned = TallSection()
        view.setPinnedSection(pinned)
        view.layoutSubtreeIfNeeded()
        #expect(card.frame.height >= 120, "the card keeps its title and a row: \(card.frame)")
        #expect(pinned.frame.maxY < card.frame.minY && card.frame.maxY < view.transcript.fieldTop, "\(pinned.frame) \(card.frame)")
        view.setPinnedSection(nil)
    }
}

/// Needs you rows taller than any pane.
private final class TallSection: NSView {
    override var fittingSize: NSSize { NSSize(width: 400, height: 2000) }
}

/// A stand-in for `feed.needsYouInChief` (the app reads it from the observable settings snapshot).
@MainActor @Observable private final class PinToggle { var on = false }

/// A stand-in for Chief Home's transcript: records what the pin puts under its header.
@MainActor private final class PinHost: FeedPinnedSectionHost {
    private(set) var pinnedSection: NSView?
    private(set) var updates = 0
    func setPinnedSection(_ view: NSView?) { pinnedSection = view; updates += 1 }
    private(set) var resizes = 0
    func pinnedSectionDidResize() { resizes += 1 }
}
