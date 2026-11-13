// SPDX-License-Identifier: GPL-3.0-or-later
import CmuxRemoteWire
import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit

// The pure parts of a preview session (PreviewStreamSession): what one look decides, the frames
// waiting for the channel, when a keyframe is forced, and what it reads from the system and how fast.

/// What one look at an agent's window decides for its stream (pure: tests cover each step).
enum PreviewStreamStep: Equatable, Sendable {
    /// Start streaming this window.
    case start(UInt32)
    /// The agent works in another window now: stream that one.
    case restart(UInt32)
    /// Keep the stream as it is.
    case keep
    /// Stop (or do not start), and tell the app why.
    case stop(ComputerUsePreview.Refusal)

    /// The step from the window streamed now and what the privacy gate says of the session's window.
    static func next(streaming current: UInt32?, gate: Result<UInt32, ComputerUsePreview.Refusal>) -> PreviewStreamStep {
        switch (current, gate) {
        case (nil, .success(let window)): .start(window)
        case (let current?, .success(let window)): current == window ? .keep : .restart(window)
        case (_, .failure(let refusal)): .stop(refusal)
        }
    }

    /// The app's status for a refusal: blocked drops any picture; the rest keep the last one, paused.
    static func state(for refusal: ComputerUsePreview.Refusal) -> String {
        switch refusal {
        case .blocked: "blocked"
        case .noWindow: "no_window"
        case .captureFailed, .permission: "paused"
        }
    }
}

/// The encoded frames waiting for a preview's channel (pure: tests cover it).
struct PreviewFrameBacklog: Equatable, Sendable {
    /// Frames handed to the writer and not yet written.
    var pending = 0
    /// Frames are dropped until the next keyframe.
    var dropping = false
    /// The encoder should make its next frame a keyframe (``takeKeyframeRequest()`` clears it).
    var wantsKeyframe = false

    /// Whether an encoded frame goes to the writer (counted as pending) or is dropped. Past `limit`
    /// pending frames the stream drops every frame until a keyframe that fits, and asks the encoder
    /// for one (again if that keyframe had to be dropped too).
    mutating func admit(keyframe: Bool, limit: Int) -> Bool {
        if keyframe, pending < limit { dropping = false }
        if !dropping, pending >= limit {
            dropping = true
            wantsKeyframe = true
        }
        if dropping {
            if keyframe { wantsKeyframe = true }
            return false
        }
        pending += 1
        return true
    }

    /// Whether the encoder should force a keyframe now; the request is taken.
    mutating func takeKeyframeRequest() -> Bool {
        defer { wantsKeyframe = false }
        return wantsKeyframe
    }
}

/// When the encoder makes a keyframe (pure: tests cover it): always at a stream's start or after
/// a new encoder, and when the app or the backlog asks, at most once per `gap`.
struct PreviewKeyframePolicy: Equatable, Sendable {
    var gap: TimeInterval
    /// A new stream or encoder: the next frame is a keyframe whatever the gap.
    var required = true
    /// The app (`K`) or the backlog asked for one.
    var asked = false
    var lastForced: Date?

    /// Whether the frame encoded at `now` is forced to be a keyframe; a forced one clears the asks.
    mutating func force(now: Date) -> Bool {
        let due = required || (asked && lastForced.map { now.timeIntervalSince($0) >= gap } ?? true)
        guard due else { return false }
        required = false
        asked = false
        lastForced = now
        return true
    }
}

/// What a preview session reads from the system: the owner and bounds of a window, the
/// ScreenCaptureKit window to stream, and a still. Tests pass their own.
struct PreviewCapture: Sendable {
    var owner: @Sendable (UInt32) -> ComputerUseActivity.App?
    var bounds: @Sendable (UInt32) -> CGRect?
    var window: @Sendable (UInt32) async throws -> SCWindow
    var still: @Sendable (UInt32, Int) async -> Result<(jpeg: Data, width: Int, height: Int), ComputerUsePreview.Refusal>

    static let live = PreviewCapture(
        owner: { ComputerUseActivityReporter.owner(ofWindow: $0) },
        bounds: { ScreenCapture.currentBounds(of: $0) },
        window: { try await ScreenCapture.window($0) },
        still: { id, side in await ComputerUsePreview.still(window: id, longSide: side) })
}

/// A preview session's pace. Tests shorten it.
struct PreviewTiming: Sendable {
    /// How often the session's window and its owner are looked at again.
    var look: DispatchTimeInterval = .milliseconds(500)
    /// The least time between two stills.
    var still: TimeInterval = 0.5
    /// The wait before a failed stream start is tried again, doubling up to ``retryMax``.
    var retryBase: TimeInterval = 2
    var retryMax: TimeInterval = 30
    /// The least time between two keyframes the app or the backlog asked for.
    var keyframeGap: TimeInterval = 0.3
}
