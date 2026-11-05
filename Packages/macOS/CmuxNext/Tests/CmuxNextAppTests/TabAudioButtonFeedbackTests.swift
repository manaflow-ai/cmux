import AppKit
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Testing

/// Lawrence 2026-10-19: "For the pane tab the audio mute button needs to be interactive and I
/// need to be able to click it to mute it properly." The click itself mutes
/// (`TabAudioToggleTests`); this suite covers what makes the speaker read as a button, as in
/// Chrome: hovering it names what a click does in a tooltip (and the tab's hover card stays
/// away so the two do not stack), and VoiceOver offers the same Mute tab / Unmute tab action.
@MainActor @Suite(.serialized, .closesItsWindows) struct TabAudioButtonFeedbackTests {
    final class Harness {
        let model: TabStripModel
        let strip: TabStripView
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 40), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        private(set) var intents: [TabStripIntent] = []

        init(audio: TabAudio) {
            var tabs = (0..<3).map { TabItem(id: TabID("tab\($0)"), title: "A page with a long enough title \($0)") }
            tabs[1].audio = audio
            model = TabStripModel(tabs: tabs, selectedID: TabID("tab0"))
            strip = TabStripView(model: model)
            strip.dragsWindowFromEmptySpace = false
            strip.frame = NSRect(x: 0, y: 0, width: 700, height: TabStripView.preferredHeight)
            window.contentView = strip
            window.orderFrontRegardless()
            strip.layoutSubtreeIfNeeded()
            model.intentHandler = { [unowned self] in intents.append($0) }
        }

        var cell: TabCell { strip.cells[TabID("tab1")]! }

        /// The speaker's center in the strip's coordinates, after the pointer entered the tab.
        func speaker() throws -> CGPoint {
            TabStripDebug.pointerMoved(in: strip, to: body())
            let rect = try #require(cell.audioButtonRect, "the tab shows no speaker")
            return strip.convert(CGPoint(x: cell.frame.minX + rect.midX, y: cell.frame.minY + rect.midY), from: strip.tabsClip)
        }

        /// Sends `type` at `point` (the strip's coordinates).
        func send(_ type: NSEvent.EventType, at point: CGPoint) {
            guard let event = NSEvent.mouseEvent(with: type, location: strip.convert(point, to: nil), modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                 context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) else { return }
            window.sendEvent(event)
        }

        /// A point on the tab's title, away from the speaker, in the strip's coordinates.
        func body() -> CGPoint {
            strip.convert(CGPoint(x: cell.frame.minX + cell.frame.width * 0.3, y: cell.frame.midY), from: strip.tabsClip)
        }
    }

    @Test(arguments: [(TabAudio.playing, "Mute tab"), (.muted, "Unmute tab")])
    func hoveringTheSpeakerNamesWhatAClickDoes(_ audio: TabAudio, _ tooltip: String) throws {
        let harness = Harness(audio: audio)
        defer { harness.window.closeAfterTest() }
        TabStripDebug.pointerMoved(in: harness.strip, to: try harness.speaker())
        #expect(harness.strip.toolTip == tooltip)
        TabStripDebug.pointerMoved(in: harness.strip, to: harness.body())
        #expect(harness.strip.toolTip == nil, "the tooltip stays after the pointer left the speaker")
    }

    /// A press on the speaker that drags away neither drags nor selects the tab, and mutes
    /// nothing; dragging back onto the speaker and releasing there still mutes (a button's press).
    @Test func aPressOnTheSpeakerNeverDragsTheTab() throws {
        let harness = Harness(audio: .playing)
        defer { harness.window.closeAfterTest() }
        let speaker = try harness.speaker()
        let away = CGPoint(x: speaker.x + 160, y: speaker.y)
        harness.send(.leftMouseDown, at: speaker)
        for step in 1...8 { harness.send(.leftMouseDragged, at: CGPoint(x: speaker.x + CGFloat(step) * 20, y: speaker.y)) }
        harness.send(.leftMouseUp, at: away)
        #expect(harness.intents.isEmpty, "a press on the speaker sent \(harness.intents)")
        #expect(harness.strip.drag == nil && harness.model.selectedID == TabID("tab0"))
        // The pointer comes back over the tab first (its x shows again, so the speaker sits where it did).
        let again = try harness.speaker()
        harness.send(.leftMouseDown, at: again)
        harness.send(.leftMouseDragged, at: away)
        harness.send(.leftMouseDragged, at: again)
        harness.send(.leftMouseUp, at: again)
        #expect(harness.intents == [.toggleAudioMute(TabID("tab1"))])
    }

    @Test(arguments: [(TabAudio.playing, "Mute tab"), (.muted, "Unmute tab")])
    func voiceOverOffersTheSameAction(_ audio: TabAudio, _ name: String) throws {
        let harness = Harness(audio: audio)
        defer { harness.window.closeAfterTest() }
        let actions = try #require(harness.cell.accessibility.accessibilityCustomActions())
        let action = try #require(actions.first { $0.name == name }, "VoiceOver offers \(actions.map(\.name))")
        #expect(action.handler?() == true)
        #expect(harness.intents == [.toggleAudioMute(TabID("tab1"))])
    }
}
