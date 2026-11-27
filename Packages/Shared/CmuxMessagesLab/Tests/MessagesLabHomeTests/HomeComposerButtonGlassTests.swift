import AppKit
import CmuxHomeCore
import Testing
@testable import MessagesLabHome

/// The "+" and emoji buttons' glass shared one NSGlassEffectContainerView as wide as the pane. A glass container draws
/// its glass itself, from one SwiftUI graph, and every width change of the pane resized it and moved the emoji glass in
/// it: the container rendered its graph again inside the layout of each divider-drag frame (Home's glass was about half
/// of its layout in the sampled drags, release-resize bp-on-2, 2026-11-26). Each button's container now hugs its glass
/// and moves with it: a width change resizes no button's container and moves no glass inside one, and the buttons still
/// stand where the bar puts them.
@MainActor @Suite(.serialized) struct HomeComposerButtonGlassTests {
    final class NoWake: ChatWakeScheduler {
        func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) {}
        func cancel() {}
    }

    static let me = ParticipantID("user_me")

    /// Home in an offscreen window at 900 pt with an empty conversation and an empty draft.
    private func home() -> (NSWindow, NSView, MessagesLabHomeView) {
        let people = [CmuxHomeCore.Participant(id: Self.me, kind: .human, displayName: "Me")]
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let id = ConversationID("conv_button_glass")
        let summary = ConversationSummary(id: id, title: "Chief", participants: people, lastSeq: 0,
                                          createdAt: base, updatedAt: base, readCursors: [:], readCursorTimes: [:])
        let store = HomeStore(source: MockHomeSource(options: .immediate))
        let view = MessagesLabHomeView(store: store, conversation: id, me: Self.me, wake: NoWake())
        var core = ProjectionCore(me: Self.me)
        let (conv, w) = core.install(id, items: [], summary: summary)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        window.contentView = container
        view.frame = container.bounds
        container.addSubview(view)
        view.controller.install(conv, windowStart: w.start, total: w.total)
        container.layoutSubtreeIfNeeded()
        return (window, container, view)
    }

    private func resize(_ view: MessagesLabHomeView, in container: NSView, to width: CGFloat) {
        view.setFrameSize(NSSize(width: width, height: 700))
        container.layoutSubtreeIfNeeded()
    }

    /// The glass container that draws `glass`: the nearest ancestor that is one.
    private func glassContainer(of glass: NSView) -> NSView? {
        sequence(first: glass, next: { $0.superview }).dropFirst().first { $0 is any LabGlassContainer }
    }

    /// Each button's container size, and its glass's rect in that container.
    private func buttonGlass(_ chrome: FieldChrome) -> (sizes: [CGSize], places: [CGRect]) {
        let glass: [NSView] = [chrome.plusGlass, chrome.emojiGlass]
        let containers = glass.map(glassContainer(of:))
        return (containers.map { $0?.frame.size ?? .zero },
                zip(glass, containers).map { g, c in c.map { g.convert(g.bounds, to: $0) } ?? .null })
    }

    @Test func aWidthChangeResizesNoButtonContainerAndMovesNoGlassInOne() throws {
        let (window, container, view) = home()
        defer { window.close() }
        let chrome = view.controller.host.fieldChrome
        try #require(!chrome.plusGlass.isHidden && !chrome.emojiGlass.isHidden, "fixture: a button is hidden at 900 pt")
        let before = buttonGlass(chrome)
        for width in [880.0, 850, 820, 790] {
            resize(view, in: container, to: width)
            let now = buttonGlass(chrome)
            #expect(now.sizes == before.sizes, "at \(width) pt a button's glass container took a new size: \(now.sizes) from \(before.sizes)")
            #expect(now.places == before.places, "at \(width) pt a button's glass moved in its container: \(now.places) from \(before.places)")
        }
    }

    /// The "+" button stays at the bar's left and the emoji button follows its right edge, as the bar lays them out.
    @Test func theButtonsStandWhereTheBarPutsThem() throws {
        let (window, container, view) = home()
        defer { window.close() }
        let chrome = view.controller.host.fieldChrome
        for width in [900.0, 820, 760] {
            resize(view, in: container, to: width)
            let plus = chrome.convert(chrome.plusGlass.bounds, from: chrome.plusGlass)
            let emoji = chrome.convert(chrome.emojiGlass.bounds, from: chrome.emojiGlass)
            let field = chrome.field.frame
            let barWidth = try #require(view.controller.demo?.compose.bounds.width)
            let layout = ComposeChromeLayout(width: barWidth)
            #expect(plus.minX == ComposeChromeLayout.margin && plus.width == ComposeChromeLayout.button,
                    "the + glass is at \(plus) in a \(width) pt pane")
            #expect(emoji.minX == layout.emojiX && emoji.width == ComposeChromeLayout.button,
                    "the emoji glass is at \(emoji) in a \(width) pt pane (the bar puts it at \(layout.emojiX))")
            #expect(plus.midY == emoji.midY && !plus.intersects(field) && !emoji.intersects(field),
                    "the buttons are off the bar's line or cover the field: + \(plus), emoji \(emoji), field \(field)")
        }
    }
}
