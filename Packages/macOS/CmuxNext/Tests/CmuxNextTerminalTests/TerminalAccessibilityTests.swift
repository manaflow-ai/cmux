import AppKit
@testable import CmuxNextTerminal
import CmuxNextWakeups
import Foundation
import Testing

/// VoiceOver in the terminal (pro audit 16): the surface is an AXTextArea, and a text area's
/// text is its AXValue with the parameterized text attributes VoiceOver reads it by (character
/// count, visible range, line for index, range for line, string for range). These read them the
/// way the accessibility server does, through the NSAccessibility overrides, on a live surface.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct TerminalAccessibilityTests {
    init() {
        _ = NSApplication.shared
        _ = GhosttyRuntime.shared
    }

    @Test func voiceOverReadsTheTerminalsText() async throws {
        let io = ScriptedTerminalIO()
        let session = TerminalSession(io: io, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 240), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            io.finish()
            window.close()
        }
        window.contentView = session.view
        session.view.frame = NSRect(x: 0, y: 0, width: 480, height: 240)
        session.view.layoutSubtreeIfNeeded()
        let view = session.surfaceView
        _ = try #require(view.surface, "libghostty created no surface")
        let lane = try #require(view.lane)

        let first = "cmux-ax-first-line", second = "cmux-ax-second-line"
        lane.processOutput(Data("\(first)\r\n\(second)\r\n".utf8))
        await lane.drained()

        #expect(view.isAccessibilityElement())
        #expect(view.accessibilityRole() == .textArea)
        let value = try #require(view.accessibilityValue() as? String, "the text area has no AXValue: VoiceOver reads no output")
        #expect(value.contains(first) && value.contains(second))

        let text = value as NSString
        #expect(view.accessibilityNumberOfCharacters() == text.length, "AXNumberOfCharacters counts UTF-16 units of AXValue")
        #expect(view.accessibilityVisibleCharacterRange() == NSRange(location: 0, length: text.length))

        let firstRange = text.range(of: first), secondRange = text.range(of: second)
        #expect(view.accessibilityString(for: secondRange) == second, "AXStringForRange reads the terminal's text")
        let firstLine = view.accessibilityLine(for: firstRange.location)
        let secondLine = view.accessibilityLine(for: secondRange.location)
        #expect(secondLine == firstLine + 1, "AXLineForIndex: the second row is the next line")
        let lineRange = view.accessibilityRange(forLine: secondLine)
        #expect(text.substring(with: lineRange).contains(second), "AXRangeForLine covers that row")
        #expect(view.accessibilityAttributedString(for: secondRange)?.string == second)
    }
}
