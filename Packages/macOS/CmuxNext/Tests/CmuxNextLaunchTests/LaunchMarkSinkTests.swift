import CmuxNextLaunch
import Darwin
import Testing

/// The bench pipe's lines (scripts/cmux-next/bench-startup.py reads `<name> <value>` per line): a time mark in ms
/// with one decimal, a value mark (p09-observability-034's page-ins) as the bare count.
struct LaunchMarkSinkTests {
    /// The lines `send` wrote into a pipe passed as `CMUX_NEXT_LAUNCH_MARKS_FD`.
    private static func lines(_ send: (LaunchMarkSink) -> Void) throws -> [String] {
        var fds: [Int32] = [0, 0]
        try #require(pipe(&fds) == 0)
        defer { close(fds[0]) }
        let sink = LaunchMarkSink(environment: [LaunchMarkSink.environmentKey: String(fds[1])])
        send(sink)
        close(fds[1])
        var bytes: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 512)
        while true {
            let count = chunk.withUnsafeMutableBytes { read(fds[0], $0.baseAddress, $0.count) }
            guard count > 0 else { break }
            bytes += chunk[0 ..< count]
        }
        return String(decoding: bytes, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    @Test func timeAndValueMarks() throws {
        let lines = try Self.lines { sink in
            sink.write(name: "did_finish_launching_end", ms: 412.36)
            sink.writeValue(name: "launch.pageins_run_loop_start", value: 3_812)
            sink.write(name: "launch.temperature.cold", ms: 412.36)
        }
        #expect(lines == ["did_finish_launching_end 412.4", "launch.pageins_run_loop_start 3812", "launch.temperature.cold 412.4"])
    }
}
