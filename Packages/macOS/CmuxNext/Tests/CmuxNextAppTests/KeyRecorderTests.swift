import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import Testing

/// The Keyboard Shortcuts page's key recorder (`KeyRecorder`): each stroke
/// is reported, Return or the fourth stroke ends it, Escape cancels it, and
/// nothing is recorded after it ends.
struct KeyRecorderTests {
    static let ctrlK = Shortcut("k", modifiers: [.control])
    static let s = Shortcut("s", modifiers: [])

    @Test func strokesAreReportedAndReturnEnds() {
        var recorder = KeyRecorder()
        #expect(recorder.record(Self.ctrlK, isEscape: false, isReturn: false) == .init(keys: [Self.ctrlK], done: false, cancelled: false))
        #expect(recorder.record(Self.s, isEscape: false, isReturn: false) == .init(keys: [Self.ctrlK, Self.s], done: false, cancelled: false))
        #expect(recorder.record(nil, isEscape: false, isReturn: true) == .init(keys: [Self.ctrlK, Self.s], done: true, cancelled: false))
        #expect(recorder.record(Self.s, isEscape: false, isReturn: false) == nil, "nothing after the end")
    }

    @Test func theFourthStrokeEndsAndEscapeCancels() {
        var recorder = KeyRecorder()
        for _ in 0..<3 { _ = recorder.record(Self.s, isEscape: false, isReturn: false) }
        #expect(recorder.record(Self.ctrlK, isEscape: false, isReturn: false)?.done == true)
        var cancelled = KeyRecorder()
        _ = cancelled.record(Self.ctrlK, isEscape: false, isReturn: false)
        #expect(cancelled.record(nil, isEscape: true, isReturn: false) == .init(keys: [Self.ctrlK], done: false, cancelled: true))
    }

    /// Return as the first key is a stroke (a binding may start with it).
    @Test func returnFirstIsAStroke() {
        var recorder = KeyRecorder()
        let returnKey = Shortcut("\r", modifiers: [])
        #expect(recorder.record(returnKey, isEscape: false, isReturn: true)?.keys == [returnKey])
    }
}
