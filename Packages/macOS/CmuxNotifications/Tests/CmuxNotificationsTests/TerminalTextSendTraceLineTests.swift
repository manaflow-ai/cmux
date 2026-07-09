import Foundation
import Testing
@testable import CmuxNotifications

/// Pins the byte-exact `reactGrab.pasteback` trace line shape the package now owns
/// (lifted from the former app-side `TerminalTextSendTracer` string assembly).
/// Uses fixed UUIDs so the 5-char `shortId` abbreviation, field order, separators,
/// and the `match=`/`surfaceReady=`/`mode=` computations are all asserted literally.
@Suite
struct TerminalTextSendTraceLineTests {
    // Distinct 5-char prefixes so each field is independently checkable.
    private let workspace = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000000")!
    private let preferred = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000000")!
    private let focused = UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000000")!
    private let focusedTerminal = UUID(uuidString: "DDDDDDDD-0000-0000-0000-000000000000")!
    private let resolved = UUID(uuidString: "EEEEEEEE-0000-0000-0000-000000000000")!
    private let surface = UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000000")!

    private var line: TerminalTextSendTraceLine {
        TerminalTextSendTraceLine(workspaceID: workspace)
    }

    @Test("sendStart line is byte-identical to the legacy format")
    func sendStart() {
        #expect(line.sendStart(
            preferredPanelID: preferred,
            focusedPanelID: focused,
            focusedTerminalPanelID: focusedTerminal,
            resolvedPanelID: resolved,
            surfaceReady: true,
            textCount: 42
        ) == "reactGrab.pasteback h2.send.start workspace=AAAAA preferred=BBBBB focused=CCCCC focusedTerminal=DDDDD resolved=EEEEE surfaceReady=1 len=42")
    }

    @Test("nil ids render as nil and surfaceReady false renders as 0")
    func sendStartNils() {
        #expect(line.sendStart(
            preferredPanelID: nil,
            focusedPanelID: nil,
            focusedTerminalPanelID: nil,
            resolvedPanelID: nil,
            surfaceReady: false,
            textCount: 0
        ) == "reactGrab.pasteback h2.send.start workspace=AAAAA preferred=nil focused=nil focusedTerminal=nil resolved=nil surfaceReady=0 len=0")
    }

    @Test("sendImmediate line")
    func sendImmediate() {
        #expect(line.sendImmediate(targetPanelID: preferred, textCount: 7)
            == "reactGrab.pasteback h2.send.immediate workspace=AAAAA target=BBBBB len=7")
    }

    @Test("sendSent mode reflects delayed flag")
    func sendSent() {
        #expect(line.sendSent(targetPanelID: preferred, delayed: true, textCount: 3)
            == "reactGrab.pasteback h2.send.sent workspace=AAAAA target=BBBBB mode=delayed len=3")
        #expect(line.sendSent(targetPanelID: preferred, delayed: false, textCount: 3)
            == "reactGrab.pasteback h2.send.sent workspace=AAAAA target=BBBBB mode=immediate len=3")
    }

    @Test("finishIfReady line")
    func finishIfReady() {
        #expect(line.finishIfReady(
            preferredPanelID: preferred,
            focusedPanelID: focused,
            resolvedPanelID: resolved,
            surfaceReady: false,
            alreadyResolved: true
        ) == "reactGrab.pasteback h2.finishIfReady workspace=AAAAA preferred=BBBBB focused=CCCCC resolved=EEEEE surfaceReady=0 alreadyResolved=1")
    }

    @Test("panelsChanged line")
    func panelsChanged() {
        #expect(line.panelsChanged(focusedPanelID: focused)
            == "reactGrab.pasteback h2.panelsChanged workspace=AAAAA focused=CCCCC")
    }

    @Test("surfaceReadyEvent match computation")
    func surfaceReadyEvent() {
        #expect(line.surfaceReadyEvent(surfaceID: preferred, preferredPanelID: preferred)
            == "reactGrab.pasteback h2.surfaceReadyEvent workspace=AAAAA surface=BBBBB target=BBBBB match=1")
        #expect(line.surfaceReadyEvent(surfaceID: surface, preferredPanelID: preferred)
            == "reactGrab.pasteback h2.surfaceReadyEvent workspace=AAAAA surface=FFFFF target=BBBBB match=0")
    }

    @Test("sendTimeout line")
    func sendTimeout() {
        #expect(line.sendTimeout(
            preferredPanelID: preferred,
            focusedPanelID: focused,
            focusedTerminalPanelID: focusedTerminal
        ) == "reactGrab.pasteback h2.send.timeout workspace=AAAAA preferred=BBBBB focused=CCCCC focusedTerminal=DDDDD")
    }

    @Test("focusEvent and firstResponderEvent match computation")
    func focusAndFirstResponder() {
        #expect(line.focusEvent(surfaceID: preferred, preferredPanelID: preferred)
            == "reactGrab.pasteback h1.focusEvent workspace=AAAAA surface=BBBBB target=BBBBB match=1")
        #expect(line.firstResponderEvent(surfaceID: surface, preferredPanelID: preferred)
            == "reactGrab.pasteback h1.firstResponderEvent workspace=AAAAA surface=FFFFF target=BBBBB match=0")
    }
}
