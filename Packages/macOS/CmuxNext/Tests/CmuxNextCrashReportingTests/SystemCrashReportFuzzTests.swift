import CmuxFuzzSupport
import Foundation
import Sentry
import Testing
@testable import CmuxNextCrashReporting

/// ``SystemCrashReport`` reads `.ips` files that other processes wrote and
/// macOS may still be writing, and its result goes to Sentry. Any bytes give `.crash`,
/// `.other` or `.incomplete`, never a trap; a crash comes only from a bug type 309 header, its
/// frames and images only from the report's own lists, and its Sentry event builds. Seeded
/// property tests on CmuxFuzzSupport (long mode: CMUX_FUZZ_SECONDS; a failure prints its
/// CMUX_FUZZ_SEED and CMUX_FUZZ_ITERATIONS replay).
@Suite struct SystemCrashReportFuzzTests {
    static let crashHeader = #"{"app_name":"cmux-tui","bug_type":"309","name":"cmux-tui","os_version":"macOS 15.7.4 (24G517)","incident_id":"0B8D4A51-6C9E-4F0F-8F53-3C2D7B4F9E20"}"#

    /// A helper crash (bug type 309) body: the crashed thread is the second one, with an
    /// Objective-C throw stack and two images.
    static let crashBody = """
    {
      "procName" : "cmux-tui",
      "procPath" : "/Applications/cmux NEXT Nightly.app/Contents/Resources/bin/cmux-tui",
      "incident" : "0B8D4A51-6C9E-4F0F-8F53-3C2D7B4F9E20",
      "exception" : {"codes":"0x0000000000000001, 0x0000000000000000","type":"EXC_BAD_ACCESS","signal":"SIGSEGV"},
      "termination" : {"flags":0,"code":11,"namespace":"SIGNAL","indicator":"Segmentation fault: 11"},
      "faultingThread" : 1,
      "threads" : [
        {"id":1,"frames":[{"imageOffset":4000,"symbol":"mach_msg2_trap","imageIndex":1}]},
        {"triggered":true,"id":2,"frames":[{"imageOffset":777,"imageIndex":0},{"imageOffset":12,"symbol":"main","imageIndex":0}]}
      ],
      "lastExceptionBacktrace" : [{"imageOffset":9,"symbol":"objc_exception_throw","imageIndex":1}],
      "usedImages" : [
        {"source":"P","arch":"arm64","base":4294967296,"size":16777216,"uuid":"3f0c9e43-7a61-3c8e-9c1a-2b7f5d0e9a11","path":"/Applications/cmux NEXT Nightly.app/Contents/Resources/bin/cmux-tui","name":"cmux-tui"},
        {"source":"P","arch":"arm64e","base":6442450944,"size":1048576,"uuid":"8a1b2c3d-4e5f-3a6b-9c7d-8e9f0a1b2c3d","name":"libsystem_kernel.dylib"}
      ]
    }
    """

    /// A hang report (bug type 288): the JSON header, then spindump text.
    static let hangReport = """
    {"app_name":"cmux NEXT Nightly","app_version":"0.70.0","bug_type":"288","os_version":"macOS 26.1 (25B78)","name":"cmux NEXT Nightly"}
    Date/Time:        2026-10-21 09:00:00.000 -0700
    Duration:         6.12s
    Process:          cmux NEXT Nightly [4242]
    Thread 0x1a2b    61 samples (1-61)    priority 47 (base 47)
      61  main + 12 (cmux NEXT Nightly + 777) [0x100000309]
    """

    static let crashReport = Data((crashHeader + "\n" + crashBody).utf8)

    /// The seeds: a whole crash, a whole hang, and crashes cut where macOS may still be writing.
    static var seeds: [Data] {
        let headerEnd = crashHeader.utf8.count
        return [crashReport, Data(hangReport.utf8), crashReport.prefix(headerEnd), crashReport.prefix(headerEnd + 1),
                crashReport.prefix(headerEnd + crashBody.utf8.count / 2)]
    }

    static let mutator = FuzzMutator(dictionary: [
        "\"faultingThread\"", "\"threads\"", "\"frames\"", "\"triggered\"", "\"imageIndex\"", "\"imageOffset\"",
        "\"usedImages\"", "\"base\"", "\"size\"", "\"uuid\"", "\"path\"", "\"lastExceptionBacktrace\"", "\"309\"",
        "\"bug_type\"", "-1", "0", "18446744073709551615", "18446744073709551616", "9223372036854775807",
        "-9223372036854775808", "1e300", "-0.5", "null", "true", "{", "}", "[", "]", ",", ":", "\"", "\n",
    ].map { Data($0.utf8) })

    /// Values a JSON field can hold in place of the one the parser expects (`any Sendable`: a
    /// static is shared across the test target's concurrency domains; `UInt64.max` bridges to
    /// the same unsigned NSNumber that JSONSerialization writes).
    static let numbers: [any Sendable] = [
        -1, 0, 1, 2, 777, Int.max, Int.min, UInt64.max, -0.5, 3.75, 1e19, 1e300, -1e300, true, false,
    ]
    static let strings = ["", "0", "1", "main", "/", "/Users/alice/Library/x.dylib", "é🙂", "309"]

    /// One input, its choices read from `data` (the libFuzzer entry).
    static func oneInput(_ data: Data) throws {
        var rng = FuzzRNG(replaying: data)
        try check(rng.bool() ? structured(&rng) : mutated(&rng))
    }

    /// A seed after one mutation pass, or random bytes one time in eight.
    static func mutated(_ rng: inout FuzzRNG) -> Data {
        guard !rng.oneIn(8), let base = rng.element(of: seeds) else { return rng.bytes(512) }
        return mutator.mutate(base, using: &rng)
    }

    // MARK: - Generated reports

    /// The crash fixture with up to four fields replaced by wrong types and extreme values,
    /// under a 309 header (another type one time in eight), cut short one time in eight.
    static func structured(_ rng: inout FuzzRNG) throws -> Data {
        var body = try JSONSerialization.jsonObject(with: Data(crashBody.utf8)) as? [String: Any] ?? [:]
        for _ in 0...rng.below(4) {
            switch rng.below(7) {
            case 0: body["faultingThread"] = rng.oneIn(4) ? scalar(&rng) : number(&rng)
            case 1: body["threads"] = rng.oneIn(4) ? scalar(&rng) : list(&rng, below: 4, thread)
            case 2: body["usedImages"] = rng.oneIn(4) ? scalar(&rng) : list(&rng, below: 5, image)
            case 3: body["lastExceptionBacktrace"] = rng.oneIn(4) ? scalar(&rng) : list(&rng, below: 6, frame)
            case 4:
                let exception: [String: Any] = ["type": scalar(&rng), "signal": scalar(&rng)]
                body["exception"] = rng.bool() ? scalar(&rng) : exception as Any
            case 5:
                let termination: [String: Any] = ["indicator": scalar(&rng)]
                body["termination"] = rng.bool() ? scalar(&rng) : termination as Any
            default: body[rng.element(of: ["procName", "procPath", "incident"]) ?? "procName"] = scalar(&rng)
            }
        }
        try FuzzRun.check(JSONSerialization.isValidJSONObject(body), "a generated body is JSON")
        let header = rng.oneIn(8) ? String(hangReport.prefix { $0 != "\n" }) : crashHeader
        var data = Data(header.utf8)
        data.append(UInt8(ascii: "\n"))
        data.append(try JSONSerialization.data(withJSONObject: body))
        return rng.oneIn(8) ? data.prefix(rng.below(data.count + 1)) : data
    }

    static func number(_ rng: inout FuzzRNG) -> Any {
        rng.element(of: numbers) ?? 0
    }

    static func scalar(_ rng: inout FuzzRNG) -> Any {
        switch rng.below(5) {
        case 0: number(&rng)
        case 1: rng.element(of: strings) ?? ""
        case 2: NSNull()
        case 3: [Any]()
        default: [String: Any]()
        }
    }

    /// Fewer than `n` values from `make`.
    static func list(_ rng: inout FuzzRNG, below n: Int, _ make: (inout FuzzRNG) -> Any) -> Any {
        var values: [Any] = []
        for _ in 0..<rng.below(n) { values.append(make(&rng)) }
        return values
    }

    static func thread(_ rng: inout FuzzRNG) -> Any {
        guard !rng.oneIn(5) else { return scalar(&rng) }
        let triggered: Any = rng.bool() ? true as Any : scalar(&rng)
        let frames: Any = rng.oneIn(4) ? scalar(&rng) : list(&rng, below: 6, frame)
        let thread: [String: Any] = ["triggered": triggered, "frames": frames]
        return thread
    }

    static func frame(_ rng: inout FuzzRNG) -> Any {
        guard !rng.oneIn(5) else { return scalar(&rng) }
        let frame: [String: Any] = ["imageIndex": number(&rng), "imageOffset": number(&rng), "symbol": scalar(&rng)]
        return frame
    }

    static func image(_ rng: inout FuzzRNG) -> Any {
        guard !rng.oneIn(5) else { return scalar(&rng) }
        let image: [String: Any] = ["base": number(&rng), "size": number(&rng), "uuid": scalar(&rng), "path": scalar(&rng),
                                    "name": scalar(&rng), "arch": scalar(&rng)]
        return image
    }

    // MARK: - Properties

    /// The lists a report holds, read loosely: what bounds the parsed frames and images.
    struct Lists {
        var isCrash = false
        var longestThread = 0
        var exceptionFrames = 0
        var images = 0

        init(_ data: Data) {
            guard let newline = data.firstIndex(of: UInt8(ascii: "\n")),
                  let header = try? JSONSerialization.jsonObject(with: data[..<newline]) as? [String: Any],
                  let body = try? JSONSerialization.jsonObject(with: data[data.index(after: newline)...]) as? [String: Any]
            else { return }
            isCrash = header["bug_type"] as? String == "309"
            longestThread = (body["threads"] as? [Any] ?? []).map { (($0 as? [String: Any])?["frames"] as? [Any])?.count ?? 0 }
                .max() ?? 0
            exceptionFrames = (body["lastExceptionBacktrace"] as? [Any])?.count ?? 0
            images = (body["usedImages"] as? [Any])?.count ?? 0
        }
    }

    /// Any bytes: the two entry points agree, a crash is bounded by the report's own lists and
    /// its Sentry event builds with one stack per exception, no longer than the report's.
    static func check(_ data: Data) throws {
        let contents = SystemCrashReport.contents(of: data)
        guard case .crash(let report) = contents else {
            return try FuzzRun.check(SystemCrashReport(data: data) == nil, "init(data:) agrees with \(contents)")
        }
        try FuzzRun.check(SystemCrashReport(data: data) == report, "init(data:) agrees with contents(of:)")
        let lists = Lists(data)
        try FuzzRun.check(lists.isCrash, "a crash comes only from a bug type 309 header")
        try FuzzRun.check(report.frames.count <= lists.longestThread, "\(report.frames.count) crashed-thread frames")
        try FuzzRun.check(report.exceptionFrames.count <= lists.exceptionFrames, "\(report.exceptionFrames.count) throw frames")
        try FuzzRun.check(report.images.count <= lists.images, "\(report.images.count) images of \(lists.images)")
        let event = SystemCrashEvent(report: report).event()
        let stacks = (event.exceptions ?? []).map { $0.stacktrace?.frames.count ?? 0 }
        try FuzzRun.check(stacks.count == (report.exceptionFrames.isEmpty ? 1 : 2), "\(stacks.count) exceptions")
        try FuzzRun.check((stacks.last ?? 0) <= report.frames.count, "a crash stack of \(stacks.last ?? 0) frames")
        try FuzzRun.check(stacks.count == 1 || stacks[0] <= report.exceptionFrames.count, "a throw stack of \(stacks[0]) frames")
        try FuzzRun.check((event.debugMeta ?? []).count == report.images.filter { !$0.uuid.isEmpty }.count,
                          "one debug image per image with a UUID")
    }

    // MARK: - Known answers

    @Test func theSeedReportsParse() throws {
        guard case .crash(let report) = SystemCrashReport.contents(of: Self.crashReport) else {
            Issue.record("the crash fixture does not parse")
            return
        }
        #expect(report.processName == "cmux-tui")
        #expect(report.exceptionType == "EXC_BAD_ACCESS" && report.signal == "SIGSEGV")
        #expect(report.frames.map(\.imageOffset) == [777, 12])
        #expect(report.exceptionFrames.map(\.symbol) == ["objc_exception_throw"])
        #expect(report.images.map(\.name) == ["cmux-tui", "libsystem_kernel.dylib"])
        #expect(SystemCrashEvent(report: report).event().exceptions?.count == 2)
        #expect(SystemCrashReport.contents(of: Data(Self.hangReport.utf8)) == .other)
    }

    /// A report cut anywhere (macOS still writing it) is incomplete: never a crash, never a trap.
    @Test func aTruncatedReportIsIncomplete() {
        for count in 0..<Self.crashReport.count {
            #expect(SystemCrashReport.contents(of: Self.crashReport.prefix(count)) == .incomplete, "\(count) bytes")
        }
        let hang = Data(Self.hangReport.utf8)
        let headerEnd = hang.firstIndex(of: UInt8(ascii: "\n")) ?? hang.endIndex
        for count in 0...hang.count {
            let expected: SystemCrashReport.Contents = count > headerEnd ? .other : .incomplete
            #expect(SystemCrashReport.contents(of: hang.prefix(count)) == expected, "\(count) bytes")
        }
    }

    // MARK: - Seeded runs

    @Test func mutatedReportsNeverTrap() throws {
        let run = try FuzzRun("SystemCrashReport.bytes", seed: 0x2921, iterations: 2_000)
        try run.forEachInput(run.corpus(seeds: Self.seeds), mutator: Self.mutator, Self.check)
    }

    @Test func reportsWithWrongTypesAndExtremeValuesNeverTrap() throws {
        try FuzzRun("SystemCrashReport.structured", seed: 0x2922, iterations: 2_000).forEach { rng in
            try Self.check(Self.structured(&rng))
        }
    }

    @Test func oneInputTakesAnyBytes() throws {
        let run = try FuzzRun("SystemCrashReport.oneInput", seed: 0x2923, iterations: 256)
        // Choice tapes: the generated branch with each field edit, and the mutated branch.
        let tapes = (0..<7).map { Data([1, 0, UInt8($0), 1]) } + [Data([0, 1, 0]), Data([0, 1, 1])]
        try run.forEachInput(run.corpus(seeds: tapes), Self.oneInput)
    }
}
