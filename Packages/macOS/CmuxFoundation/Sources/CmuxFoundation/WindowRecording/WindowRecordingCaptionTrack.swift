internal import Foundation

/// The captions burned into a recording's frames.
///
/// An agent that records a tour wants the clip to say what it did, not just
/// show a cursor moving: `cmux record note "open Settings"` appends one here,
/// and the recorder draws whichever note is current when it writes a frame.
/// Automation commands push their own notes through the same sink, which is
/// what `--overlay-actions` turns on.
public struct WindowRecordingCaptionTrack: Sendable, Equatable {
    public struct Note: Sendable, Equatable {
        public let offsetSeconds: Double
        public let text: String

        public init(offsetSeconds: Double, text: String) {
            self.offsetSeconds = offsetSeconds
            self.text = text
        }
    }

    /// How long one note stays on screen after the moment it was pushed.
    public static let defaultVisibleSeconds: Double = 2.5
    /// Longest caption drawn; a whole prompt would cover the window.
    public static let maximumCharacters = 120

    public let visibleSeconds: Double
    private var notes: [Note] = []

    public init(visibleSeconds: Double = WindowRecordingCaptionTrack.defaultVisibleSeconds) {
        self.visibleSeconds = max(0.1, visibleSeconds)
    }

    public var isEmpty: Bool { notes.isEmpty }
    public var notesInOrder: [Note] { notes }
    public var count: Int { notes.count }

    /// Records one caption. Returns false when the text carries nothing to draw.
    ///
    /// Notes arrive from the recorder's own clock, so they normally append; an
    /// out-of-order offset is still inserted in order rather than dropped,
    /// which keeps `caption(atOffsetSeconds:)` a plain search.
    @discardableResult
    public mutating func append(text: String, atOffsetSeconds offset: Double) -> Bool {
        let collapsed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return false }
        let clipped = collapsed.count > Self.maximumCharacters
            ? String(collapsed.prefix(Self.maximumCharacters - 1)) + "\u{2026}"
            : collapsed
        let note = Note(
            offsetSeconds: offset.isFinite ? max(0, offset) : 0,
            text: clipped
        )
        if let last = notes.last, last.offsetSeconds <= note.offsetSeconds {
            notes.append(note)
        } else {
            let index = notes.firstIndex { $0.offsetSeconds > note.offsetSeconds } ?? notes.endIndex
            notes.insert(note, at: index)
        }
        return true
    }

    /// The caption to draw on the frame captured at `offset`, if any.
    public func caption(atOffsetSeconds offset: Double) -> String? {
        guard offset.isFinite else { return nil }
        var current: Note?
        for note in notes {
            if note.offsetSeconds > offset { break }
            current = note
        }
        guard let current, offset - current.offsetSeconds < visibleSeconds else {
            return nil
        }
        return current.text
    }
}
