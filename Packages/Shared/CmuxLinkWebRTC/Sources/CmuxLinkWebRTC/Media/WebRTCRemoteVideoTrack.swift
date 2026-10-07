import CmuxLink
import Foundation
import os
@preconcurrency import WebRTC

/// The dialer's side of a published video track: attached sinks receive
/// decoded frames from libwebrtc's renderer callback.
final class WebRTCRemoteVideoTrack: WebRTCMediaBacking, @unchecked Sendable {
    private let track: RTCVideoTrack
    private let states = MediaTrackStates()
    // carve-out: renderer adapters are libwebrtc objects; never held while
    // calling into libwebrtc.
    private let renderers = OSAllocatedUnfairLock(uncheckedState: [ObjectIdentifier: VideoRendererAdapter]())

    init(track: RTCVideoTrack) {
        self.track = track
    }

    func states() async -> AsyncStream<MediaTrackState> { states.stream() }

    func attach(_ sink: any MediaFrameSink) async {
        guard states.current != .ended else { return }
        let adapter = VideoRendererAdapter(sink: sink)
        let previous = renderers.withLockUnchecked { renderers in
            defer { renderers[ObjectIdentifier(sink)] = adapter }
            return renderers[ObjectIdentifier(sink)]
        }
        if let previous { track.remove(previous) }
        track.add(adapter)
    }

    func detach(_ sink: any MediaFrameSink) async {
        if let adapter = renderers.withLockUnchecked({ $0.removeValue(forKey: ObjectIdentifier(sink)) }) {
            track.remove(adapter)
        }
    }

    /// Receivers do not publish.
    func push(_ frame: MediaFrame) async {}

    func stop() async { end() }

    func end() {
        guard states.end() else { return }
        let all = renderers.withLockUnchecked { renderers in
            defer { renderers = [:] }
            return Array(renderers.values)
        }
        for adapter in all { track.remove(adapter) }
    }
}
