import CmuxSocketStackSampler
import Darwin

/// Reads a bounded best-effort stack without changing the target's suspend count.
nonisolated struct MachThreadStackAddressSampler {
    static func captureAddresses(for thread: thread_act_t, maxFrames: Int) -> [UInt] {
        guard maxFrames > 0 else { return [] }
        var addresses = [UInt](repeating: 0, count: min(maxFrames, 128))
        let capturedCount = addresses.withUnsafeMutableBufferPointer { buffer in
            CMUXCaptureThreadStackAddresses(thread, buffer.baseAddress, buffer.count)
        }
        return Array(addresses.prefix(capturedCount))
    }
}
