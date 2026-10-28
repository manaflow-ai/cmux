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

    /// The line table counts UTF-16 units, as NSRange does: a row after an emoji starts two units in.
    @Test func linesAndRangesCountUTF16Units() {
        let text = TerminalAccessibleText("a\u{1F600}b\nsecond\n\nlast")
        #expect(text.length == ("a\u{1F600}b\nsecond\n\nlast" as NSString).length)
        #expect(text.line(for: 0) == 0)
        #expect(text.line(for: 4) == 0, "the first row's newline is on the first line")
        #expect(text.line(for: 5) == 1)
        #expect(text.range(forLine: 1) == NSRange(location: 5, length: 7))
        #expect(text.string(for: NSRange(location: 5, length: 6)) == "second")
        #expect(text.range(forLine: 2) == NSRange(location: 12, length: 1), "an empty row is its newline")
        #expect(text.range(forLine: 3) == NSRange(location: 13, length: 4))
        #expect(text.range(forLine: 4).location == NSNotFound)
        #expect(text.line(for: 999) == 3, "an index past the end is on the last line")
        #expect(text.string(for: NSRange(location: 15, length: 9)) == nil)
        #expect(TerminalAccessibleText("").range(forLine: 0) == NSRange(location: 0, length: 0))
    }

    /// One read serves a burst of requests; new output shows once the kept read is older than its life.
    @Test func aReadIsKeptForItsLifetimeOnly() {
        var cache = TerminalAccessibleTextCache()
        var reads = 0
        let start = ContinuousClock.now
        let read = { (string: String) in { () -> String? in reads += 1; return string } }
        #expect(cache.text(now: start, read: read("old")).string == "old")
        #expect(cache.text(now: start + .milliseconds(100), read: read("new")).string == "old")
        #expect(reads == 1, "a request in the burst reads the viewport again")
        #expect(cache.text(now: start + TerminalAccessibleTextCache.lifetime, read: read("new")).string == "new")
        #expect(reads == 2)
        #expect(cache.text(now: start, read: read("earlier")).string == "earlier", "a clock that went back reads again")
    }
}
