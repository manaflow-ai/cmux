// DEBUG builds only: the screen-stream eval's on-phone latency probe. Nothing here ships in Release.
#if DEBUG && canImport(UIKit)
import CoreVideo
import Foundation
import QuartzCore
import WebRTC

/// Times the glass-to-glass marker (`cmux-tui/crates/cmux-rd-host/scripts/mac-marker`: 20 cells,
/// counter LSB first, then guards 1,0,1,0) as the iPhone app shows it: when a decoded frame first
/// carries a counter value, and when the app's own renderer (`ScreenVideoView`'s
/// `RTCMTLVideoView`) first presents a drawable holding that value. Both on `CACurrentMediaTime`,
/// the clock Core Animation and Metal's `presentedTime` use. Set `ScreenSession.debugVideoProbe`
/// before the viewer makes its video view (scripts/measure/screen-stream-eval/targets/iphone-sim.sh).
// crash-allow: the geometry is immutable, and every mutable field is read and written only under `lock`.
public final class ScreenPresentProbe: NSObject, RTCVideoRenderer, @unchecked Sendable {

    /// When a marker value first showed: decoded, and presented on the display.
    public struct Shown: Sendable {
        public var decoded: CFTimeInterval?
        public var presented: CFTimeInterval?
    }

    /// One cell's width over the frame width, and the marker's top over the frame height.
    public let cellFraction: Double
    public let originY: Double
    private let lock = NSLock()
    private var current: UInt16?
    private var size = CGSize.zero
    /// Frame timestamp (ns) to the marker value it carried, for the last 128 decoded frames.
    private var valueByTimestamp: [Int64: UInt16] = [:]
    private var timestamps: [Int64] = []
    private var decodedAt: [UInt16: CFTimeInterval] = [:]
    private var presentedAt: [UInt16: CFTimeInterval] = [:]
    private var waiter: (value: UInt16, resume: CheckedContinuation<Shown?, Never>)?
    private var presentedTimes = 0
    private var handlerTimes = 0
    private var presents = 0
    /// Why presents are not observed (no Metal view under `RTCMTLVideoView`), or nil.
    private var hookProblem: String?

    public init(cellFraction: Double, originY: Double) {
        self.cellFraction = cellFraction
        self.originY = originY
    }

    public var value: UInt16? { lock.withLock { current } }
    public var frameSize: CGSize { lock.withLock { size } }

    /// How presents were timed: drawables with a `presentedTime`, ones timed at their presented
    /// handler (the system reported 0), and the hook's problem when it could not be installed.
    public var presentClock: [String: Any] {
        lock.withLock { () -> [String: Any] in
            ["presents": presents, "presented_time": presentedTimes, "handler_time": handlerTimes,
             "hook_problem": hookProblem.map { $0 as Any } ?? NSNull()]
        }
    }

    // MARK: RTCVideoRenderer (libwebrtc's decode thread)

    public func setSize(_ size: CGSize) {}

    public func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }
        let now = CACurrentMediaTime()
        guard let value = Self.marker(in: frame, cellFraction: cellFraction, originY: originY) else { return }
        lock.withLock {
            size = CGSize(width: Int(frame.width), height: Int(frame.height))
            current = value
            if valueByTimestamp[frame.timeStampNs] == nil {
                timestamps.append(frame.timeStampNs)
                if timestamps.count > 128 { valueByTimestamp[timestamps.removeFirst()] = nil }
            }
            valueByTimestamp[frame.timeStampNs] = value
            if decodedAt[value] == nil { decodedAt[value] = now }
        }
    }

    // MARK: The view's present hook

    /// The renderer presented a drawable holding the frame stamped `timeStampNs`.
    /// `presentedTime` is Metal's (0 when the system reports none), `callbackAt` when the handler ran.
    func presented(timeStampNs: Int64, presentedTime: CFTimeInterval, callbackAt: CFTimeInterval) {
        let resume = lock.withLock { () -> (CheckedContinuation<Shown?, Never>, Shown)? in
            presents += 1
            let at: CFTimeInterval
            if presentedTime > 0 {
                presentedTimes += 1
                at = presentedTime
            } else {
                handlerTimes += 1
                at = callbackAt
            }
            guard let value = valueByTimestamp[timeStampNs] else { return nil }
            if presentedAt[value] == nil { presentedAt[value] = at }
            // A frame at or past the awaited value ends the wait: the renderer may skip a frame
            // the decoder replaced before the next display refresh.
            guard let waiter, Self.reached(value, waiter.value) else { return nil }
            self.waiter = nil
            let shown = Shown(decoded: firstDecoded(atOrPast: waiter.value), presented: at)
            return (waiter.resume, shown)
        }
        if let resume { resume.0.resume(returning: resume.1) }
    }

    func hookFailed(_ problem: String) {
        lock.withLock { hookProblem = problem }
    }

    // MARK: Waiting

    /// When `value` first showed: the first presented drawable at or past it, with the first
    /// decoded frame at or past it. Nil when `cancelWait` ends the wait first.
    public func firstShown(_ value: UInt16) async -> Shown? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Shown?, Never>) in
            let done = lock.withLock { () -> Shown? in
                // The earliest present of any value at or past it (a Dictionary has no order).
                if let presented = presentedAt.filter({ Self.reached($0.key, value) }).map(\.value).min() {
                    return Shown(decoded: firstDecoded(atOrPast: value), presented: presented)
                }
                waiter = (value, continuation)
                return nil
            }
            if let done { continuation.resume(returning: done) }
        }
    }

    /// Ends a wait that did not finish in time; returns the decoded time of the awaited value, if
    /// it was decoded but never presented.
    public func cancelWait() -> CFTimeInterval? {
        let (resume, decoded) = lock.withLock { () -> (CheckedContinuation<Shown?, Never>?, CFTimeInterval?) in
            defer { waiter = nil }
            return (waiter?.resume, waiter.flatMap { firstDecoded(atOrPast: $0.value) })
        }
        resume?.resume(returning: nil)
        return decoded
    }

    /// Forgets every value's times before the next input, so a stale value never ends a wait.
    public func reset() {
        lock.withLock {
            decodedAt.removeAll()
            presentedAt.removeAll()
        }
    }

    private func firstDecoded(atOrPast value: UInt16) -> CFTimeInterval? {
        decodedAt.filter { Self.reached($0.key, value) }.map(\.value).min()
    }

    /// `value` is `target` or within half the counter's range after it (the counter wraps).
    private static func reached(_ value: UInt16, _ target: UInt16) -> Bool {
        value &- target < 0x8000
    }

    // MARK: The marker

    private static func marker(in frame: RTCVideoFrame, cellFraction: Double, originY: Double) -> UInt16? {
        let width = Double(frame.width)
        let cell = cellFraction * width
        let top = originY * Double(frame.height)
        let y = Int(top + cell / 2)
        guard cell > 0, y >= 0, y < Int(frame.height), Int(19.5 * cell) < Int(frame.width) else { return nil }
        func decode(_ luma: (Int, Int) -> UInt8) -> UInt16? {
            var bits = [Bool](repeating: false, count: 20)
            for i in 0 ..< 20 {
                bits[i] = luma(Int((Double(i) + 0.5) * cell), y) > 125
            }
            guard Array(bits[16...]) == [true, false, true, false] else { return nil }
            return bits[..<16].enumerated().reduce(0) { $0 | (($1.element ? 1 : 0) << UInt16($1.offset)) }
        }
        if let buffer = frame.buffer as? RTCCVPixelBuffer {
            let pixels = buffer.pixelBuffer
            CVPixelBufferLockBaseAddress(pixels, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddressOfPlane(pixels, 0) else { return nil }
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            return decode { x, y in bytes[y * stride + x] }
        }
        let i420 = frame.buffer.toI420()
        return decode { x, y in i420.dataY[y * Int(i420.strideY) + x] }
    }
}
#endif
