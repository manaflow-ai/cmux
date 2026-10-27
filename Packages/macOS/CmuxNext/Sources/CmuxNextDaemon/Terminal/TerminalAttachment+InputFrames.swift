import CmuxNextIPC
import CmuxNextWakeups
import Foundation
import os

/// A stream view's keys as INPUT frames (p05-ipc-096; cmux-tui/spec/transports.md, "An INPUT frame"): the raw
/// bytes behind a 16-byte header that names the view's stream and the key press's flow id. No JSON and no
/// base64 per key, no request id and no reply: the daemon runs the frame on the stream's sequence and writes
/// the terminal the way `send` does (frame_dispatch.rs, p05-ipc-078); a write that fails comes back as the
/// stream's `input-failed` event. Chrome sends input the same way: a one-way message on the widget's own
/// associated pipe, ordered with its other messages (third_party/blink/public/mojom/input/input_handler.mojom,
/// `WidgetInputHandler.DispatchNonBlockingEvent`).
///
/// Frames go at input priority from the calling thread, Ghostty's `io_write_cb` thread, so on an idle
/// connection the key leaves on that thread with no queue hop (FrameWriter's inline path, p05-ipc-140).
extension TerminalAttachment {
    /// INPUT (cmux-ipc frame.rs `FrameKind::Input`).
    static let inputFrameKind: UInt8 = 9

    /// The stream this view's keys go to as INPUT frames: its own stream on a connection that holds
    /// `ipc-frames-v2`. Nil sends them as `send` lines: a view on a connection of its own (INPUT on stream 0
    /// is a bad message), or a connection the daemon granted no frames.
    nonisolated var inputFrameStream: UInt16? {
        guard let stream, transport.wireGrants.frames else { return nil }
        return stream.id
    }

    /// Writes `data` as INPUT frames on `stream`, in call order with every earlier key of this view, then marks
    /// the press `flow` names as sent, as the `send` line path does.
    nonisolated func sendInputFrames(_ data: Data, stream: UInt16, flow: UInt64?) {
        var failure: SocketWriteFailure?
        Self.forEachInputFrame(data, stream: stream, flow: flow) { frame in
            failure = transport.sendFrame(frame, priority: .input)
            return failure == nil
        }
        switch failure {
        case nil:
            if let flow { TypingLatencyProbe.shared.mark(.socketSubmit, flow: flow) }
        case .closed?, .peerClosed?:
            logger.debug("input dropped after close")
        case let failure?:
            logger.error("input frame not written: \(failure.description, privacy: .public)")
        }
    }

    /// Writes `data` as one `send {surface, bytes}` line (base64 in JSON): a view with no framed stream.
    nonisolated func sendInputLine(_ data: Data, flow: UInt64?) {
        let (surface, logger) = (self.surface, self.logger)
        do {
            try transport.sendNoReply(cmd: SendInputRequest.command, onError: { error in
                logger.error("send failed: \(error.description, privacy: .public)")
            }) { id in
                try WireCoding.encodeRequest(SendInputRequest(surface: surface, bytes: data, flow: flow), id: id)
            }
            if let flow { TypingLatencyProbe.shared.mark(.socketSubmit, flow: flow) }
        } catch {
            logger.debug("input dropped after close: \(String(describing: error), privacy: .public)")
        }
    }

    /// Calls `body` with each INPUT frame of `data`, in order, until it returns false. Bytes past
    /// `maxPayload` go in further frames; only the first names the press (`flow`), since only one write
    /// echoes it.
    static func forEachInputFrame(_ data: Data, stream: UInt16, flow: UInt64?,
                                  maxPayload: Int = Int(truncatingIfNeeded: FrameHeader.maxPayloadCap),
                                  _ body: (Data) -> Bool) {
        let size = max(1, maxPayload)
        var rest = data
        var press = flow
        while !rest.isEmpty {
            let payload = rest.prefix(size)
            guard body(inputFrame(payload, stream: stream, flow: press)) else { return }
            rest = rest.dropFirst(payload.count)
            press = nil
        }
    }

    /// One INPUT frame: magic 0xFF, kind 9, stream (LE u16), payload length (LE u32), flow id (LE u64, 0 for
    /// none), then `payload` (cmux-ipc frame.rs `FrameHeader`, `Aux::FlowId`).
    static func inputFrame(_ payload: Data, stream: UInt16, flow: UInt64?) -> Data {
        var frame = Data(capacity: FrameHeader.byteCount + payload.count)
        frame.append(FrameHeader.magic)
        frame.append(inputFrameKind)
        appendLittleEndian(stream, to: &frame)
        appendLittleEndian(UInt32(truncatingIfNeeded: payload.count), to: &frame)
        appendLittleEndian(flow ?? 0, to: &frame)
        frame.append(payload)
        return frame
    }

    private static func appendLittleEndian<Value: FixedWidthInteger & UnsignedInteger>(_ value: Value,
                                                                                      to data: inout Data) {
        for shift in stride(from: 0, to: Value.bitWidth, by: 8) {
            data.append(UInt8(truncatingIfNeeded: value >> shift))
        }
    }
}
