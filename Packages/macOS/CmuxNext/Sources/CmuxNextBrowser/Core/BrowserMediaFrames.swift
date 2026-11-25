import Foundation

/// The latest media report of each frame of one document (`BrowserMediaState+Scripts` reports per
/// frame, with an id its observer picks for its document), and the one the tab shows.
///
/// Every frame of a page reports on its own: an ad iframe that stops reports null for itself, and
/// that must not erase the main frame's paused video. So a report replaces only its own frame's
/// entry, and the tab shows, in order: a video in Picture in Picture, then the frame that started
/// playing last, then the frame that reported last; a frame's sound with no element (Web Audio,
/// `isSoundOnly`) shows only when no frame has an element, and otherwise marks the shown one
/// `isOtherSound` (the speaker), so it never hides a video from the media hub. A null report, or
/// the frame's `pagehide`, drops its entry; a new main document (`committed`) or a process exit
/// drops them all.
nonisolated struct BrowserMediaFrames: Sendable {
    private struct Entry: Sendable {
        var media: BrowserMediaState
        /// When the entry began or last changed between playing, paused and floating.
        var order: UInt64
    }

    private var entries: [String: Entry] = [:]
    private var counter: UInt64 = 0

    /// Takes `frame`'s report (nil: it plays nothing now) and returns what the tab shows.
    mutating func apply(_ media: BrowserMediaState?, from frame: String) -> BrowserMediaState? {
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

    /// What the tab shows: the floating video, else the frame that started playing last, else
    /// the frame that reported last; nil when no frame plays anything.
    var current: BrowserMediaState? {
        guard var shown = entries.values.max(by: { Self.rank($0) < Self.rank($1) })?.media else { return nil }
        if !shown.isSounding, entries.values.contains(where: { $0.media.isSounding }) { shown.isOtherSound = true }
        return shown
    }

    private static func rank(_ entry: Entry) -> (Int, Int, Int, UInt64) {
        let element = entry.media.isSoundOnly ? 0 : 1
        return (entry.media.isPictureInPicture ? 1 : 0, entry.media.isPlaying ? element : 0, element, entry.order)
    }
}
