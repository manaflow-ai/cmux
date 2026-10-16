import Foundation
import Testing
@testable import CmuxTerminalPrediction

/// Every read from a remote surface is copied into the inbox on the IO
/// thread and scanned byte by byte on the main actor, whether or not a key
/// is pending. `scan` returns an array with one enum per byte.
///
/// Measured on an idle M-series mini, `swift test -c release`: scan 54 ms
/// per MiB, `observedOutput` 62 ms per MiB (16 MiB/s), against 0.14 ms to
/// map the same MiB into an enum array. A remote `cat` of a log, or a
/// build streaming over a LAN link, outruns the main actor several times
/// over, and the inbox has no bound while it catches up.
struct PredictionBreakPerfTests {
    /// Output with nothing in flight must not be classified byte by byte.
    /// Measured against touching every byte once in the same build, so the
    /// bound holds on a loaded machine and in a debug build alike.
    @Test func scanningARemoteBuildLogOnTheMainActor() {
        let line = Array("\u{1B}[32mCompiling\u{1B}[0m cmux-terminal-prediction v0.1.0 (/src/Packages/Shared/CmuxTerminalPrediction) target=arm64\r\n".utf8)
        var chunk: [UInt8] = []
        while chunk.count < 65_536 { chunk += line }
        let chunks = 16  // 1 MiB
        func seconds(_ body: () -> Void) -> Double {
            let start = ContinuousClock.now
            body()
            let elapsed = ContinuousClock.now - start
            return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        }
        var total = 0
        let touchEveryByte = seconds {
            for _ in 0..<chunks { for byte in chunk { total &+= Int(byte) } }
        }
        precondition(total != 1)
        var idle = TerminalPredictionEngine(isEnabled: true, isRemoteSurface: true)
        let idleSeconds = seconds {
            for index in 0..<chunks { idle.observedOutput(chunk, at: .milliseconds(index)) }
        }
        // One key typed first: its echo never comes, the first chunk
        // withdraws it, and the rest is idle output again.
        var typed = TerminalPredictionEngine(isEnabled: true, isRemoteSurface: true)
        typed.typed(printableASCII: 0x61, at: .zero)
        let typedSeconds = seconds {
            for index in 0..<chunks { typed.observedOutput(chunk, at: .milliseconds(index + 1)) }
        }
        print("PERF 1 MiB: touch every byte \(touchEveryByte) s, idle surface \(idleSeconds) s, after a key \(typedSeconds) s")
        #expect(idleSeconds < touchEveryByte, "idle output took \(idleSeconds) s against \(touchEveryByte) s to touch every byte")
        #expect(typedSeconds < touchEveryByte, "output after a key took \(typedSeconds) s against \(touchEveryByte) s to touch every byte")
    }
}

struct PredictionBreakPerfBreakdown {
    @Test func breakdown() {
        let line = Array("\u{1B}[32mCompiling\u{1B}[0m cmux-terminal-prediction v0.1.0 (/src/Packages/Shared/CmuxTerminalPrediction) target=arm64\r\n".utf8)
        var chunk: [UInt8] = []
        while chunk.count < 65_536 { chunk += line }
        func time(_ label: String, _ body: () -> Void) {
            let start = ContinuousClock.now
            body()
            print("PERF \(label): \(ContinuousClock.now - start)")
        }
        time("calibration: sum 1 MiB x16") {
            var total = 0
            for _ in 0..<16 { for byte in chunk { total &+= Int(byte) } }
            precondition(total != 1)
        }
        time("calibration: map 1 MiB into [enum] x1") {
            var out: [TerminalOutputSignal] = []
            for byte in chunk { out.append(.printable(byte)) }
            precondition(!out.isEmpty)
        }
        time("scan 1 MiB") {
            var scanner = TerminalOutputScanner()
            var n = 0
            for _ in 0..<16 { n += scanner.scan(chunk).count }
            precondition(n > 0)
        }
        time("engine 1 MiB, never typed") {
            var engine = TerminalPredictionEngine(isEnabled: true, isRemoteSurface: true)
            for index in 0..<16 { engine.observedOutput(chunk, at: .milliseconds(index)) }
        }
        time("engine 1 MiB, one key typed first") {
            var engine = TerminalPredictionEngine(isEnabled: true, isRemoteSurface: true)
            engine.typed(printableASCII: 0x61, at: .zero)
            for index in 0..<16 { engine.observedOutput(chunk, at: .milliseconds(index + 1)) }
        }
    }
}
