#if DEBUG
import Darwin
import Foundation
import Testing
@testable import CmuxMobileTerminal

/// Leo, 2026-11-14: "this is just such a f***ing hog of CPU and f***ing
/// battery and f***ing RAM as well". The energy step's `hidden-terminals-4`
/// case streams `stream 1000000 20` in four mock terminals. The mock made all
/// million rows before writing the first, about 90 MB a terminal: 360 MB of
/// the case's 450 MB footprint was the mock's rows, not the app, and their
/// allocation alone moved the footprint by about 30 MB from one build to the
/// next (read as a regression of #43046). It now makes each row as it writes it.
@MainActor
@Suite(.serialized) struct MockTerminalStreamMemoryTests {
    /// The process's `phys_footprint` (Xcode's memory gauge), in bytes.
    static func footprint() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Int64(bitPattern: info.phys_footprint) : 0
    }

    static func waitUntil(_ seconds: Double, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int(seconds * 1000)))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10)) // test: polls the mock's output until a deadline
        }
    }

    /// A long `stream` holds no more than the rows it wrote: two million rows
    /// were about 180 MB made up front before the change.
    ///
    /// The footprint is the whole test process's, and the simulator leg runs
    /// the kit's suites in parallel: another suite's allocations land in one
    /// window (79 MB on 2026-11-25, beside 0 MB with this suite alone). The
    /// least growth of three streams is the mock's own; a mock that makes the
    /// whole stream first grows every time.
    @Test func longStreamMakesItsRowsAsItWrites() async throws {
        var grown: [Int64] = []
        for _ in 0..<3 {
            grown.append(try await Self.growthByThirdRow())
            if let least = grown.min(), least < 40 << 20 { break }
        }
        let least = grown.min() ?? .max
        let line = "mock stream of 2000000 rows: footprint grew \(grown.map { $0 >> 20 }) MB by its third row"
        print(line)
        Attachment.record(Array(line.utf8), named: "mock-stream-memory.txt")
        #expect(least < 40 << 20, "the mock made the whole stream before writing it (\(least >> 20) MB)")
    }

    /// One mock shell's `stream 2000000 20`: the footprint grown by its third row.
    static func growthByThirdRow() async throws -> Int64 {
        let session = MockTerminalSession(playsIntro: false)
        var output = ""
        session.start { event in
            if case .output(let data) = event { output += String(decoding: data, as: UTF8.self) }
        }
        defer { session.stop() }
        try await waitUntil(5) { output.contains("❯") }
        try #require(output.contains("❯"), "the mock shell never showed its prompt")

        let before = footprint()
        session.send(Data("\u{3}stream 2000000 20\r".utf8))
        try await waitUntil(10) { output.contains("#0000003") }
        try #require(output.contains("#0000003"), "the stream wrote no rows")
        return footprint() - before
    }
}
#endif
