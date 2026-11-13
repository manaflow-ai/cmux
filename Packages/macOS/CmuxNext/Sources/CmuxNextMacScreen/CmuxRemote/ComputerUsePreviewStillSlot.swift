// SPDX-License-Identifier: GPL-3.0-or-later
import CmuxNextCompat
import CoreGraphics
import Foundation
import ImageIO

/// The newest decoded still of a preview stream, between its reader thread and the main queue:
/// one slot, so a slow main thread never queues stills (a newer one replaces the one waiting), each
/// still numbered so a word about an older one takes nothing.
nonisolated final class ComputerUsePreviewStillSlot: Sendable {
    /// The still waiting, the last number given, and the last number given before the slot was
    /// emptied (a word about a still from before that takes nothing).
    private struct State: ~Copyable {
        var image: CGImage?
        var next: UInt64 = 0
        var emptiedThrough: UInt64 = 0

        /// The waiting still, out of the slot.
        mutating func takeImage() -> CGImage? {
            defer { image = nil }
            return image
        }
    }
    private let slot = Mutex(State())

    init() {}

    /// Decodes `jpeg` on the calling thread (the reader's) and keeps it as the newest; its number
    /// when the main queue should be told (the slot was empty), nil when a still already waits (that
    /// word now takes this newer one) or the payload does not decode.
    func put(jpeg: Data) -> UInt64? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        return slot.withLock { slot -> UInt64? in
            slot.next += 1
            let wasEmpty = slot.image == nil
            slot.image = decoded
            return wasEmpty ? slot.next : nil
        }
    }

    /// The still waiting, taken out of the slot, for a word numbered `sequence`: only a word given
    /// after the slot was last emptied takes it (it then takes the newest still).
    func take(sequence: UInt64) -> CGImage? {
        slot.withLock { slot -> CGImage? in
            guard slot.image != nil, sequence > slot.emptiedThrough else { return nil }
            return slot.takeImage()
        }
    }

    /// Empties the slot (`blocked`, a close, another window): every word given so far is stale.
    func clear() {
        slot.withLock { slot in
            slot.image = nil
            slot.emptiedThrough = slot.next
        }
    }
}
