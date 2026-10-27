#if DEBUG
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its Swift side.
@testable import CmuxNextBrowser
import CmuxNextTestSupport
import Darwin
import Foundation
import Testing

/// The cost of one ``ChromiumHostControlChannel/send(_:stateKey:)`` (perf-hot
/// path `cef-host-control`, budget 5 us) as a distribution, on both of its
/// paths: the direct write (nothing waits; a host that reads) and the outbox
/// push (the socket is full; a host that never reads, geometry coalescing).
/// A measurement, not a gate. The channel is Debug-only, so this runs in a
/// Debug build; quote the lines with the macOS version. With CMUX_PERF_RESULT_DIR every send is
/// result-v1 (lab story swift-chromium-host-control):
///
/// ```
/// CMUX_CHROMIUM_HOST_CONTROL_BENCH=1 swift test --filter ChromiumHostControlSendBench
/// ```
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CMUX_CHROMIUM_HOST_CONTROL_BENCH"] == "1"))
struct ChromiumHostControlSendBench {
    typealias Message = ChromiumHostControlMessage

    private static let sends = 20_000

    private static func channel(fd: Int32) -> ChromiumHostControlChannel {
        ChromiumHostControlChannel(fd: fd, post: { drain in Task { @MainActor in drain() } },
                                   onMessages: { _ in }, onEnd: { _ in })
    }

    private static func geometry(_ browser: Int32, _ width: Int32) -> Message {
        Message(op: 2, fields: [.init(tag: 1, value: .i32(browser)), .init(tag: 2, value: .i32(width))])
    }

    private static func key(_ code: Int32) -> Message {
        Message(op: 5, fields: [.init(tag: 1, value: .i32(1)), .init(tag: 2, value: .i32(code))])
    }

    /// Nanoseconds of each of `sends` calls of `send(index)`, in call order.
    private static func measure(_ send: (Int) -> Bool) -> (samples: [UInt64], allSent: Bool) {
        var samples = [UInt64](repeating: 0, count: sends)
        var allSent = true
        for index in 0..<sends {
            let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            let sent = send(index)
            samples[index] = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start
            allSent = allSent && sent
        }
        return (samples, allSent)
    }

    private static func line(_ path: String, _ samples: [UInt64]) -> String {
        let sorted = samples.sorted()
        func at(_ fraction: Double) -> Double { Double(sorted[min(sorted.count - 1, Int(Double(sorted.count) * fraction))]) / 1_000 }
        return String(format: "chromium-host control send bench: macOS %@, %@, %d sends: p50 %.2f us, p95 %.2f us, p99 %.2f us, max %.2f us",
                      ProcessInfo.processInfo.operatingSystemVersionString, path, sorted.count,
                      at(0.50), at(0.95), at(0.99), Double(sorted.last ?? 0) / 1_000)
    }

    @Test func directWrite() throws {
        var pair: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        let peer = pair[1]
        // The host reads everything at once, on its own thread, until EOF.
        let reader = Thread {
            var bytes = [UInt8](repeating: 0, count: 64 * 1024)
            while bytes.withUnsafeMutableBytes({ read(peer, $0.baseAddress, $0.count) }) > 0 {}
            close(peer)
        }
        reader.start()
        let channel = Self.channel(fd: pair[0])
        let (samples, allSent) = Self.measure { channel.send(Self.key(Int32($0))) }
        print(Self.line("direct write (a reading host)", samples))
        try PerfResultWriter()?.record("swift.chromium_host_control.direct_write", unit: .us, samples: samples.map { Double($0) / 1_000 })
        #expect(allSent)
        channel.close()
    }

    @Test func outboxPush() throws {
        var pair: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        let channel = Self.channel(fd: pair[0])
        var code: Int32 = 0
        while channel.stats.pendingMessages == 0, code < 1_000_000 {
            channel.send(Self.key(code))
            code += 1
        }
        let page = ChromiumHostControlChannel.stateKey(op: 2, browser: 1)
        let (samples, allSent) = Self.measure { index in
            index % 2 == 0 ? channel.send(Self.geometry(1, Int32(index)), stateKey: page) : channel.send(Self.key(Int32(index)))
        }
        print(Self.line("outbox push (a host that never reads; geometry coalesces)", samples))
        try PerfResultWriter()?.record("swift.chromium_host_control.outbox_push", unit: .us, samples: samples.map { Double($0) / 1_000 })
        #expect(allSent)
        channel.close()
        close(pair[1])
    }
}
#endif
