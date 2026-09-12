import Foundation
import IrohLib

/// Serializes stream I/O and reassembles frames from arbitrary QUIC reads.
actor IrohLaneChannel {
    private let sendStream: SendStream
    private let recvStream: RecvStream
    var decoder = FrameDecoder(captureEncodedFrames: true)
    var pending = FIFOQueue<(frame: Frame, encoded: Data)>()
    private var eof = false
    private var protocolErrorNotified = false
    private var backpressureStallCount = 0
    private let encoder = FrameEncoder()
    private let frameTypePolicy = FrameTypePolicy()
    let onProtocolError: (@Sendable () async -> Void)?

    init(
        send: SendStream,
        recv: RecvStream,
        onProtocolError: (@Sendable () async -> Void)? = nil
    ) {
        self.sendStream = send
        self.recvStream = recv
        self.onProtocolError = onProtocolError
    }

    func sendFrame(_ frame: Frame) async throws {
        let data = try encoder.encode(frame)
        do {
            var offset = 0
            while offset < data.count {
                let remaining = data.dropFirst(offset)
                let written = try await sendStream.write(buf: Data(remaining))
                guard written > 0, written <= UInt64(remaining.count) else {
                    throw TransportError.pipeClosed
                }
                if written < UInt64(remaining.count) {
                    // A short write is the FFI-visible evidence that QUIC
                    // flow control required another turn; count it for the
                    // lane diagnostics without guessing from wall time.
                    backpressureStallCount += 1
                }
                offset += Int(written)
            }
        } catch {
            throw TransportError.pipeClosed
        }
    }

    /// Number of short writes observed while QUIC flow control was applying
    /// backpressure to this lane.
    var backpressureStalls: Int { backpressureStallCount }

    func receiveFrame() async -> Frame? {
        while pending.isEmpty && !eof {
            do {
                // First decode any complete frames left by the opening-frame
                // handoff. A coalesced lane.open + data frame must be
                // available immediately; waiting for another network read
                // here would otherwise stall a perfectly live lane.
                var frames = try decoder.feed(Data())
                let encoded = decoder.drainEncodedFrames()
                // The decoder emits one encoded byte sequence per frame. Keep
                // the pairing so a framed-to-raw handoff can replay exact wire
                // bytes, including the original JSON key order and escaping.
                guard frames.count == encoded.count else {
                    eof = true
                    break
                }
                guard appendDecoded(frames, encoded: encoded) else { break }
                if !pending.isEmpty { break }

                let data = try await recvStream.read(sizeLimit: 1 << 16)
                if data.isEmpty {
                    eof = true
                    break
                }
                frames = try decoder.feed(data)
                let encodedAfterRead = decoder.drainEncodedFrames()
                guard frames.count == encodedAfterRead.count else {
                    eof = true
                    break
                }
                guard appendDecoded(frames, encoded: encodedAfterRead) else { break }
            } catch let error as FrameCodecError {
                eof = true
                notifyProtocolError(error)
            } catch {
                eof = true
            }
        }
        return pending.popFirst()?.frame
    }

    /// Reads exactly one opening frame and leaves all coalesced bytes in the
    /// decoder remainder for a later raw-stream consumer. Unlike
    /// ``receiveFrame()``, this never attempts to parse bytes after the
    /// opening frame as JSON.
    func receiveOpenFrame() async -> Frame? {
        while !eof {
            do {
                let data = try await recvStream.read(sizeLimit: 1 << 16)
                if data.isEmpty {
                    eof = true
                    break
                }
                if let frame = try decoder.feedFirst(data) {
                    // The opening frame is consumed by the caller; do not
                    // leave its captured wire bytes in the handoff queue.
                    _ = decoder.drainEncodedFrames()
                    return frame
                }
            } catch let error as FrameCodecError {
                eof = true
                notifyProtocolError(error)
                break
            } catch {
                eof = true
                break
            }
        }
        return nil
    }

    /// Wakes a pending receive when a handshake deadline expires.
    func abortReceive() async {
        try? await recvStream.stop(errorCode: 1)
        eof = true
    }

    func finish() async {
        try? await sendStream.finish()
    }

    /// Graduation bridge: bytes the frame decoder read past the handshake
    /// frame. Raw handoff must re-inject them ahead of the stream reads.
    func drainBufferedBytes() -> Data {
        var out = Data()
        while let item = pending.popFirst() {
            // A raw peer never sends more frames after raw.open; anything
            // decoded here IS raw payload that happened to parse-attempt. Use
            // the original bytes, never a freshly encoded approximation.
            out.append(item.encoded)
        }
        out.append(decoder.drainRemainder())
        return out
    }

    private func notifyProtocolError(_ error: FrameCodecError) {
        guard !protocolErrorNotified else { return }
        protocolErrorNotified = true
        _ = error
        // Do not await the parent connection while this channel is servicing
        // the lane read: the parent's close path finishes every lane and would
        // otherwise wait on this actor recursively. The one-shot task is
        // weakly owned by the callback's parent and immediately closes the
        // native connection, which releases this read before lane cleanup.
        let callback = onProtocolError
        Task { await callback?() }
    }

    /// Applies the mandatory/optional frame-type policy at the framed receive
    /// boundary. Consumers never get a mandatory unknown frame to accidentally
    /// treat as an ignorable application message.
    private func appendDecoded(_ frames: [Frame], encoded: [Data]) -> Bool {
        guard frames.count == encoded.count else {
            eof = true
            return false
        }
        for (frame, bytes) in zip(frames, encoded) {
            if frameTypePolicy.classify(frame.type) == .fatalUnknown {
                eof = true
                notifyProtocolError(.unknownMandatoryType(frame.type))
                return false
            }
            pending.append((frame: frame, encoded: bytes))
        }
        return true
    }
}
