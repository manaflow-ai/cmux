import Foundation
import Testing
@testable import CmuxFoundation

@Suite struct WindowRecordingCaptionTrackTests {
    @Test func noNotesDrawNoCaption() {
        let track = WindowRecordingCaptionTrack()

        #expect(track.isEmpty)
        #expect(track.caption(atOffsetSeconds: 0) == nil)
    }

    @Test func aNoteIsDrawnFromItsOffsetUntilItExpires() {
        var track = WindowRecordingCaptionTrack(visibleSeconds: 2)
        track.append(text: "open Settings", atOffsetSeconds: 1)

        #expect(track.caption(atOffsetSeconds: 0.9) == nil)
        #expect(track.caption(atOffsetSeconds: 1) == "open Settings")
        #expect(track.caption(atOffsetSeconds: 2.9) == "open Settings")
        #expect(track.caption(atOffsetSeconds: 3) == nil)
    }

    @Test func aLaterNoteReplacesAnEarlierOneImmediately() {
        var track = WindowRecordingCaptionTrack(visibleSeconds: 10)
        track.append(text: "first", atOffsetSeconds: 0)
        track.append(text: "second", atOffsetSeconds: 1)

        #expect(track.caption(atOffsetSeconds: 0.5) == "first")
        #expect(track.caption(atOffsetSeconds: 1) == "second")
        #expect(track.count == 2)
    }

    @Test func outOfOrderNotesAreStillOrdered() {
        var track = WindowRecordingCaptionTrack(visibleSeconds: 10)
        track.append(text: "late", atOffsetSeconds: 5)
        track.append(text: "early", atOffsetSeconds: 1)

        #expect(track.notesInOrder.map(\.text) == ["early", "late"])
        #expect(track.caption(atOffsetSeconds: 2) == "early")
    }

    @Test func whitespaceIsCollapsedAndBlankNotesAreDropped() {
        var track = WindowRecordingCaptionTrack()

        let drewCaption = track.append(text: "  click\n  Settings  ", atOffsetSeconds: 0)
        let drewBlank = track.append(text: "   \n ", atOffsetSeconds: 1)

        #expect(drewCaption)
        #expect(!drewBlank)
        #expect(track.caption(atOffsetSeconds: 0) == "click Settings")
        #expect(track.count == 1)
    }

    @Test func longCaptionsAreClippedRatherThanCoveringTheWindow() {
        var track = WindowRecordingCaptionTrack()
        track.append(text: String(repeating: "a", count: 400), atOffsetSeconds: 0)
        let caption = track.caption(atOffsetSeconds: 0)

        #expect(caption?.count == WindowRecordingCaptionTrack.maximumCharacters)
        #expect(caption?.hasSuffix("\u{2026}") == true)
    }

    @Test func negativeAndBrokenOffsetsLandAtTheStart() {
        var track = WindowRecordingCaptionTrack(visibleSeconds: 5)
        track.append(text: "start", atOffsetSeconds: -3)
        track.append(text: "nan", atOffsetSeconds: .nan)

        #expect(track.notesInOrder.allSatisfy { $0.offsetSeconds == 0 })
        #expect(track.caption(atOffsetSeconds: .nan) == nil)
    }

    @Test func noteStorageKeepsOnlyABoundedRecentTail() {
        var track = WindowRecordingCaptionTrack(visibleSeconds: 10_000)

        for offset in 0..<(WindowRecordingCaptionTrack.maximumNotes + 25) {
            track.append(text: "note \(offset)", atOffsetSeconds: Double(offset))
        }

        #expect(track.count == WindowRecordingCaptionTrack.maximumNotes + 25)
        #expect(track.notesInOrder.count == WindowRecordingCaptionTrack.maximumNotes)
        #expect(track.notesInOrder.first?.text == "note 25")
        #expect(track.notesInOrder.last?.text == "note 536")
        #expect(track.caption(atOffsetSeconds: 400) == "note 400")
    }

    @Test func lookupFindsTheLatestOfManyOrderedAndOutOfOrderNotes() {
        var track = WindowRecordingCaptionTrack(visibleSeconds: 20)
        for offset in stride(from: 500, through: 0, by: -1) {
            track.append(text: "note \(offset)", atOffsetSeconds: Double(offset))
        }

        #expect(track.caption(atOffsetSeconds: 249.9) == "note 249")
        #expect(track.caption(atOffsetSeconds: 250) == "note 250")
        #expect(track.caption(atOffsetSeconds: 500) == "note 500")
    }
}
