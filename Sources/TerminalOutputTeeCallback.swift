import Foundation

/// One C callback fans raw PTY output out to every opt-in cmux consumer.
let cmuxTerminalOutputTeeCallback: @convention(c) (
    UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UInt
) -> Void = { userdata, bytes, length in
    guard let userdata, let bytes, length > 0 else { return }
    let context = Unmanaged<TerminalOutputTeeContext>.fromOpaque(userdata).takeUnretainedValue()
    let count = Int(length)
    bytes.withMemoryRebound(to: UInt8.self, capacity: count) { rebound in
        let buffer = UnsafeBufferPointer(start: rebound, count: count)
        MobileTerminalByteTee.shared.append(surfaceID: context.surfaceID, bytes: buffer)
        context.consume(buffer)
    }
}
