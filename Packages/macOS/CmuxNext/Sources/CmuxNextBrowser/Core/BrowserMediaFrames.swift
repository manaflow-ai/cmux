import Foundation

/// The latest media report of each frame of one document (`BrowserMediaState+Scripts` reports per
/// frame, with an id its observer picks for its document), and the one the tab shows.
///
/// Every frame of a page reports on its own: an ad iframe that stops reports null for itself, and
/// that must not erase the main frame's paused video. So a report replaces only its own frame's
/// entry, and the tab shows, in order: a video in Picture in Picture, then the frame that started
/// playing last, then the frame that reported last. A null report, or the frame's `pagehide`,
/// drops its entry; a new main document (`committed`) or a process exit drops them all.
///
/// A frame that goes with no word of its own (a removed cross-origin iframe, whose `pagehide`
/// post its process may never deliver; a crashed subframe) is found by a roll call: when the
/// engine says a frame detached, ``suspectAll()`` marks every entry, the tab asks every observer
/// to report again (`BrowserMediaState.rollCallScript`), each report clears its frame's mark, and
/// ``dropSuspects()`` at the roll call's deadline drops the frames that did not answer.
nonisolated struct BrowserMediaFrames: Sendable {
    private struct Entry: Sendable {
        var media: BrowserMediaState
        /// When the entry began or last changed between playing, paused and floating.
        var order: UInt64
    }

    private var entries: [String: Entry] = [:]
    private var counter: UInt64 = 0
    /// The frames a running roll call has not heard from yet.
    private var suspects: Set<String> = []

    /// Takes `frame`'s report (nil: it plays nothing now) and returns what the tab shows.
    mutating func apply(_ media: BrowserMediaState?, from frame: String) -> BrowserMediaState? {
        suspects.remove(frame)
        if let media {
            if let old = entries[frame], old.media.isPlaying == media.isPlaying,
               old.media.isPictureInPicture == media.isPictureInPicture {
                entries[frame]?.media = media
            } else {
                counter &+= 1
                entries[frame] = Entry(media: media, order: counter)
            }
        } else {
            entries[frame] = nil
        }
        return current
    }

    /// A frame may have gone (the engine said one detached): every frame that has an entry must
    /// report again before ``dropSuspects()``.
    mutating func suspectAll() {
        suspects = Set(entries.keys)
    }

    /// The roll call's deadline: drops the frames that did not report since ``suspectAll()``, and
    /// returns what the tab shows.
    mutating func dropSuspects() -> BrowserMediaState? {
        for frame in suspects { entries[frame] = nil }
        suspects = []
        return current
    }

    /// What the tab shows: the floating video, else the frame that started playing last, else
    /// the frame that reported last; nil when no frame plays anything.
    var current: BrowserMediaState? {
        entries.values.max { Self.rank($0) < Self.rank($1) }?.media
    }

    private static func rank(_ entry: Entry) -> (Int, Int, UInt64) {
        (entry.media.isPictureInPicture ? 1 : 0, entry.media.isPlaying ? 1 : 0, entry.order)
    }
}
