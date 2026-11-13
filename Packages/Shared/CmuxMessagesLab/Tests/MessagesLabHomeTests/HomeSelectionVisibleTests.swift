import AppKit
import CmuxHomeCore
import CmuxHomeRender
import Testing
@testable import MessagesLabHome

/// The transcript's text selection shows on every surface (issue https://github.com/manaflow-ai/cmux/issues/38145:
/// "when I highlight text I can't see the selection"). MessagesLab's highlight is a screen blend measured on
/// Messages' dark bubble; a screen blend only lightens, so on the light appearance's white page and light grey
/// bubble, or a light theme's, it drew nothing the eye could see. The highlight now takes the blend that stands
/// out from the bubble under it, and a drag in a real `ChatController` draws it in both appearances.
@MainActor @Suite(.serialized) struct HomeSelectionVisibleTests {
    final class NoWake: ChatWakeScheduler {
        func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) {}
        func cancel() {}
    }

    typealias Style = SelectionHighlightStyle

    static func rgb(_ c: NSColor) throws -> Style.RGB { try #require(Style.components(c)) }

    /// How far the highlight drawn in `style` stands from `surface`.
    static func shown(_ style: Style, on surface: Style.RGB) -> CGFloat {
        Style.contrast(style.composite(over: surface), surface)
    }

    // MARK: The fill against the surface

    /// The bug: MessagesLab's screen blend on the light page and the light received bubble is ~1:1.
    @Test func theScreenBlendAloneIsInvisibleOnLightSurfaces() {
        for surface in [Style.RGB(r: 1, g: 1, b: 1), Style.RGB(r: 233 / 255, g: 233 / 255, b: 235 / 255)] {
            #expect(Self.shown(.screen, on: surface) < 1.1)
        }
    }

    /// Light and dark appearance (no theme): the received bubble shows the selection (the highlight is clipped to
    /// the bubble body, so the page under it never matters).
    @Test(arguments: [false, true])
    func theHighlightShowsOnTheMeasuredPalette(light: Bool) throws {
        let saved = (Fixture.lightAppearance, Fixture.theme)
        defer { Fixture.lightAppearance = saved.0; Fixture.theme = saved.1 }
        Fixture.theme = nil
        Fixture.lightAppearance = light
        for surface in [Fixture.incoming] {
            let s = try Self.rgb(surface)
            let ratio = Self.shown(Style.style(on: s), on: s)
            #expect(ratio >= Style.surfaceFloor, "\(light ? "light" : "dark") \(surface): \(ratio)")
        }
    }

    /// Every theme and bubble style the composer contrast suite covers (light, dark, Dracula, Solarized Light;
    /// iMessage, theme and Chat Colors): the received bubble shows the selection, and a sent
    /// bubble is never worse than either blend alone.
    @Test(arguments: HomeComposerContrastTests.cases)
    func theHighlightShowsOnEveryTheme(_ c: HomeComposerContrastTests.Case) throws {
        let box = PaletteScope.box(for: FixtureTheme(active: HomeComposerContrastTests.palette(c)))
        try PaletteScope.with(box) {
            for surface in [Fixture.incoming] {
                let s = try Self.rgb(surface)
                let ratio = Self.shown(Style.style(on: s), on: s)
                #expect(ratio >= Style.surfaceFloor, "\(c.testDescription) \(surface): \(ratio)")
            }
            let sent = try Self.rgb(Fixture.outgoing)
            #expect(Self.shown(Style.style(on: sent), on: sent) >= max(Self.shown(.screen, on: sent), Self.shown(.multiply, on: sent)))
        }
    }

    // MARK: A drag in the real transcript

    private func pane() -> (NSWindow, ChatController) {
        let me = ParticipantID("user_me"), chief = ParticipantID("agent_chief")
        let people = [CmuxHomeCore.Participant(id: me, kind: .human, displayName: "Me"),
                      CmuxHomeCore.Participant(id: chief, kind: .agent, displayName: "Chief", agentClass: .chief)]
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let items = (1...4).map { i in
            TranscriptItem(key: IdempotencyKey("k\(i)"), seq: Seq(i), author: i % 2 == 0 ? me : chief,
                           parts: [.text("Message number \(i) with a few words to select")], createdAt: base.addingTimeInterval(Double(i)),
                           delivery: .committed, messageID: MessageID("msg_\(i)"))
        }
        let summary = ConversationSummary(id: ConversationID("conv_visible"), title: "Chief", participants: people, lastSeq: 4,
                                          createdAt: base, updatedAt: base, readCursors: [:], readCursorTimes: [:])
        var core = ProjectionCore(me: me)
        let (conv, w) = core.install(ConversationID("conv_visible"), items: items, summary: summary)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 700), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let controller = ChatController(host: HostView(frame: NSRect(x: 0, y: 0, width: 600, height: 700)), wake: NoWake())
        window.contentView = controller.host
        controller.install(conv, windowStart: w.start, total: w.total)
        controller.host.layoutSubtreeIfNeeded()
        controller.demo?.layoutIfNeeded()
        controller.demo?.collection.layoutIfNeeded()
        return (window, controller)
    }

    /// A drag across a received bubble selects its text and draws the highlight in the row, in a style that
    /// stands out from that bubble, in the light and the dark appearance.
    @Test(arguments: [false, true], [false, true])
    func aDragSelectsAndTheHighlightShows(light: Bool, mine: Bool) throws {
        let saved = (Fixture.lightAppearance, Fixture.theme)
        defer { Fixture.lightAppearance = saved.0; Fixture.theme = saved.1 }
        Fixture.theme = nil
        Fixture.lightAppearance = light
        let (window, controller) = pane()
        defer { window.close() }
        let demo = try #require(controller.demo)
        let row = try #require(demo.lastTextRow(mine: mine))
        let selection = controller.selection
        selection.mouseDown(CGPoint(x: row.body.minX + 14, y: row.body.midY))
        #expect(selection.mouseDragged(CGPoint(x: row.body.minX + 60, y: row.body.midY)))
        #expect(selection.mouseDragged(CGPoint(x: row.body.maxX - 14, y: row.body.midY)))
        #expect(selection.mouseUp(), "the drag is a selection, not a click")
        #expect(!selection.selectedText.isEmpty)

        let cell = try #require(demo.collection.visibleCells.compactMap { $0 as? RowCell }.first { !$0.isHidden && $0.key == row.key })
        #expect(cell.selectionHighlight.path.map { !$0.boundingBoxOfPath.isEmpty } == true, "no highlight drawn in the row")
        #expect(cell.selectionHighlight.superlayer != nil)
        let style = try #require(cell.selectionHighlightStyle)
        #expect(cell.selectionHighlight.compositingFilter as? String == style.blend.rawValue)
        let bubble = try Self.rgb(mine ? Fixture.outgoing : Fixture.incoming)
        let ratio = Self.shown(style, on: bubble)
        if mine {
            // The measured sent blue is saturated: neither blend reaches the neutral floor; the stronger one draws.
            #expect(ratio >= max(Self.shown(.screen, on: bubble), Self.shown(.multiply, on: bubble)))
        } else {
            #expect(ratio >= Style.surfaceFloor, "\(light ? "light" : "dark") received bubble: \(ratio)")
        }
    }
}
