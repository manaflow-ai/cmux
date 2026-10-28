import CmuxNextWakeups
import Foundation
import Sentry
import Testing
@testable import CmuxNextCrashReporting

/// p01-process task 226: a Crashpad dump of the Chromium Host or a helper becomes a report with the
/// exception, the signal and the crashed thread's frames, and never holds the page's URL or title that
/// Chromium writes into its crash keys. The dump is built here as Crashpad writes one on macOS
/// (minidump_extensions.h); the same bytes read back with the Python `minidump` package (threads,
/// modules, exception, misc info) when this test was written.
@Suite struct ChromiumMinidumpTests {
    static let stackBase: UInt64 = 0x7_0000_0000
    static let hostBase: UInt64 = 0x1_0000_0000
    static let frameworkBase: UInt64 = 0x2_0000_0000
    static let hostUUID = "3f0c9e43-7a61-3c8e-9c1a-2b7f5d0e9a11"
    static let frameworkUUID = "8a1b2c3d-4e5f-3a6b-9c7d-8e9f0a1b2c3d"
    static let hostPath = "/Applications/cmux.app/Contents/MacOS/cmux Chromium Host"
    static let frameworkPath =
        "/Applications/cmux.app/Contents/Frameworks/Chromium Embedded Framework.framework/Versions/A/Chromium Embedded Framework"

    @Test func readsTheExceptionTheStackAndTheModules() throws {
        let dump = try ChromiumMinidump(data: SyntheticMinidump.renderer())
        #expect(dump.reportID == "aabbccdd-1122-3344-5566-77889900eeff")
        #expect(dump.processID == 4242)
        #expect(dump.exceptionType == 1, "EXC_BAD_ACCESS, recovered from the EXC_CRASH")
        #expect(dump.exceptionAddress == Self.frameworkBase + 0x1234)
        #expect(dump.signal == SIGSEGV)
        #expect(dump.architecture == .arm64)
        #expect(dump.stack == [Self.frameworkBase + 0x1234, Self.hostBase + 0x500, Self.frameworkBase + 0x2000],
                "the pc, then each frame record's return address")
        #expect(dump.modules.map(\.uuid) == [Self.hostUUID, Self.frameworkUUID])
        #expect(dump.modules.map(\.name) == ["cmux Chromium Host", "Chromium Embedded Framework"])
    }

    /// The acceptance's grep: Chromium's URL and title crash keys never reach the report, its JSON lines or
    /// its Sentry event.
    @Test func keepsNoURLOrTitle() throws {
        let dump = try ChromiumMinidump(data: SyntheticMinidump.renderer())
        #expect(dump.annotations == ["ptype": "renderer", "pid": "4242"])
        let report = ChromiumMinidumpReport(date: Date(timeIntervalSince1970: 0), file: URL(fileURLWithPath: "/tmp/x.dmp"),
                                            dump: dump, symbols: ["Crash()", nil, nil])
        let event = SystemCrashEvent(report: report.systemReport, source: .crashpad).event()
        // debug.crashes and the crash report folder show `jsonObject`; Sentry gets the event.
        let texts = [String(describing: event.serialize()), String(describing: report.jsonObject),
                     report.frames.map(\.line).joined(separator: "\n"), report.dump.annotations.description]
        for text in texts {
            for secret in ["secret.example", "https://", "Secret Page Title", "url-chunk", "top-origin"] {
                #expect(!text.contains(secret), "\(secret) in \(text)")
            }
        }
        #expect(event.tags?["crash_source"] == "crashpad")
        #expect(report.jsonObject["frames"] as? [String] == report.frames.map(\.line))
        #expect(report.jsonObject["symbolized_frames"] as? Int == 1)
        #expect(report.jsonObject["signal"] as? String == "SIGSEGV")
    }

    @Test func framesNameTheirImageAndOffset() throws {
        let dump = try ChromiumMinidump(data: SyntheticMinidump.renderer())
        let report = ChromiumMinidumpReport(date: Date(), file: URL(fileURLWithPath: "/tmp/x.dmp"), dump: dump,
                                            symbols: ["base::ImmediateCrash()", nil, nil])
        #expect(report.processType == "renderer")
        #expect(!report.isBrowserProcess)
        #expect(report.pid == 4242)
        #expect(report.exceptionName == "EXC_BAD_ACCESS")
        #expect(report.signalName == "SIGSEGV")
        #expect(report.frames.map(\.line) == [
            "Chromium Embedded Framework + 0x1234 base::ImmediateCrash()",
            "cmux Chromium Host + 0x500",
            "Chromium Embedded Framework + 0x2000",
        ])
        let system = report.systemReport
        #expect(system.processName == "cmux Chromium Host")
        #expect(system.frames.map(\.imageIndex) == [1, 0, 1])
        #expect(system.frames.map(\.imageOffset) == [0x1234, 0x500, 0x2000])
        #expect(system.images.map(\.uuid) == [Self.hostUUID, Self.frameworkUUID])
    }

    @Test func theHostsOwnDumpIsTheBrowserProcess() throws {
        let dump = try ChromiumMinidump(data: SyntheticMinidump.build(processType: "browser"))
        let report = ChromiumMinidumpReport(date: Date(), file: URL(fileURLWithPath: "/tmp/x.dmp"), dump: dump)
        #expect(report.isBrowserProcess, "its .ips report is sent instead (BrowserCrashForwardingEnabled)")
    }

    @Test func refusesWhatIsNotAMinidump() {
        #expect(throws: ChromiumMinidump.ReadError.notMinidump) { try ChromiumMinidump(data: Data("not a dump".utf8)) }
        #expect(throws: ChromiumMinidump.ReadError.truncated) { try ChromiumMinidump(data: Data([0x4D, 0x44, 0x4D, 0x50])) }
    }

    /// Crashpad may still be writing a dump, and a dump is another process's bytes: every cut and every
    /// one-byte change reads or throws, never traps.
    @Test func anyCutOrChangedByteReadsOrThrows() {
        let whole = SyntheticMinidump.renderer()
        for length in stride(from: 0, through: whole.count, by: 7) {
            _ = try? ChromiumMinidump(data: whole.prefix(length))
        }
        for index in stride(from: 0, to: whole.count, by: 3) {
            var changed = whole
            changed[changed.startIndex + index] ^= 0xFF
            _ = try? ChromiumMinidump(data: changed)
        }
    }

    @Test func aSelfReferencingFrameRecordStopsTheWalk() {
        let registers = ChromiumMinidump.Registers(architecture: .arm64, pc: 0x10, fp: 0x1000)
        let frames = ChromiumMinidump.walk(registers, mask: 0x0000_7FFF_FFFF_FFFF) { address in
            address == 0x1000 ? 0x1000 : 0x20  // [fp] points at itself
        }
        #expect(frames == [0x10, 0x20])
    }

    @Test func symbolizesOnlyImagesWhoseFileIsTheDumpsBuild() throws {
        let dump = try ChromiumMinidump(data: SyntheticMinidump.renderer())
        let report = ChromiumMinidumpReport(date: Date(), file: URL(fileURLWithPath: "/tmp/x.dmp"), dump: dump)
        // The host on disk is this build; the framework on disk is another one.
        let symbolizer = ChromiumMinidumpSymbolizer(processes: FakeAtos(output: "")) { url in
            url.path == Self.hostPath ? [MachOSlice(uuid: Self.hostUUID, arch: "arm64")]
                : [MachOSlice(uuid: "00000000-0000-0000-0000-000000000000", arch: "arm64")]
        }
        let jobs = symbolizer.jobs(for: report)
        #expect(jobs == [ChromiumMinidumpSymbolizer.Job(path: Self.hostPath, arch: "arm64", base: Self.hostBase, frames: [1],
                                                        addresses: [Self.hostBase + 0x4FF])])
        #expect(jobs.first?.arguments == ["-o", Self.hostPath, "-arch", "arm64", "-l", "0x100000000", "0x1000004ff"])
    }

    @Test func atosOutputNamesTheFrames() async throws {
        let dump = try ChromiumMinidump(data: SyntheticMinidump.renderer())
        let report = ChromiumMinidumpReport(date: Date(), file: URL(fileURLWithPath: "/tmp/x.dmp"), dump: dump)
        let job = ChromiumMinidumpSymbolizer.Job(path: Self.frameworkPath, arch: "arm64", base: Self.frameworkBase,
                                                 frames: [0, 2], addresses: [Self.frameworkBase + 0x1234, Self.frameworkBase + 0x1FFF])
        let atos = FakeAtos(output: "base::ImmediateCrash() (in Chromium Embedded Framework) (immediate_crash.h:176)\n0x200001fff\n")
        let symbols = await ChromiumMinidumpSymbolizer(processes: atos) { _ in [] }.symbols(for: report, jobs: [job])
        #expect(symbols == ["base::ImmediateCrash() (immediate_crash.h:176)", nil, nil])
        #expect(ChromiumMinidumpSymbolizer.symbol(fromAtosLine: "main (in cmux) ") == "main")
        #expect(ChromiumMinidumpSymbolizer.symbol(fromAtosLine: "  ") == nil)
    }

    @Test func readsAMachOHeadersUUID() {
        #expect(MachOSlice.slice(SyntheticMinidump.machHeader(uuid: Self.hostUUID, subtype: 0))
            == MachOSlice(uuid: Self.hostUUID, arch: "arm64"))
        #expect(MachOSlice.slice(SyntheticMinidump.machHeader(uuid: Self.hostUUID, subtype: 2))?.arch == "arm64e")
        #expect(MachOSlice.slice([0xCA, 0xFE, 0xBA, 0xBE]) == nil)
        let fat: [UInt8] = [0xCA, 0xFE, 0xBA, 0xBE, 0, 0, 0, 2]
            + [1, 0, 0, 7, 0, 0, 0, 3, 0, 0, 0x40, 0, 0, 0, 0x10, 0, 0, 0, 0, 14]
            + [1, 0, 0, 12, 0, 0, 0, 0, 0, 0, 0x80, 0, 0, 0, 0x10, 0, 0, 0, 0, 14]
        #expect(MachOSlice.fatOffsets(fat) == [0x4000, 0x8000])
    }

    /// The database reads each dump once, and none from before its first read.
    @Test func theDatabaseReturnsEachNewDumpOnce() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "chromium-dumps-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let pending = root.appending(path: "Crashpad/pending")
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
        try SyntheticMinidump.renderer().write(to: pending.appending(path: "before-first-read.dmp"))
        let database = ChromiumCrashpadDatabase(directory: root.appending(path: "Crashpad"),
                                                stateFile: root.appending(path: "state/chromium-dumps.json"))
        #expect(database.takeNew().isEmpty, "a dump from before the first read is marked seen, not read")
        try SyntheticMinidump.renderer().write(to: pending.appending(path: "crash.dmp"))
        try Data("partial".utf8).write(to: pending.appending(path: "crash.dmp.tmp"))
        let reports = database.takeNew()
        #expect(reports.map(\.file.lastPathComponent) == ["crash.dmp"])
        #expect(reports.first?.processType == "renderer")
        #expect(database.takeNew().isEmpty)
        // Crashpad moves an uploaded or skipped dump to completed/: the same dump, still seen.
        try FileManager.default.createDirectory(at: root.appending(path: "Crashpad/completed"), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: pending.appending(path: "crash.dmp"),
                                         to: root.appending(path: "Crashpad/completed/crash.dmp"))
        #expect(database.takeNew().isEmpty)
    }
}

/// Answers every `atos` run with the same output.
private struct FakeAtos: ProcessRunning {
    let output: String

    func outcome(of request: ProcessRequest) async throws -> ProcessOutcome {
        ProcessOutcome(status: 0, exited: true, output: Data(output.utf8))
    }
}

/// A Crashpad minidump as Crashpad writes one on macOS (layout: minidump_extensions.h and dbghelp's
/// `MINIDUMP_*`, packed to 4 bytes): a renderer that crashed with SIGSEGV in the framework, two modules,
/// and crash keys that hold a URL and a title.
enum SyntheticMinidump {
    static func renderer() -> Data { build(processType: "renderer") }

    static func build(processType: String) -> Data {
        var out = Writer(base: 32 + 5 * 12)
        let stackBase = ChromiumMinidumpTests.stackBase
        var stack = [UInt8](repeating: 0, count: 0x400)
        put(&stack, 0x100, [stackBase + 0x200, ChromiumMinidumpTests.hostBase + 0x500])
        put(&stack, 0x200, [0, ChromiumMinidumpTests.frameworkBase + 0x2000])
        let stackOffset = out.add(stack)
        var context = [UInt8](repeating: 0, count: 912)
        put32(&context, 0, 0x0040_0000 | 0x7)
        put(&context, 8 + 29 * 8, [stackBase + 0x100, ChromiumMinidumpTests.hostBase + 0x400])  // fp, lr
        put(&context, 256, [stackBase + 0x80, ChromiumMinidumpTests.frameworkBase + 0x1234])  // sp, pc
        let contextOffset = out.add(context)
        var streams: [(UInt32, Int, Int)] = []

        var threads = le32(2)
        threads += le32(1) + le32(0) + le32(0) + le32(0) + le64(0) + le64(0) + le32(0) + le32(0) + le32(0) + le32(0)
        threads += le32(7) + le32(0) + le32(0) + le32(0) + le64(0) + le64(stackBase) + le32(UInt32(stack.count))
            + le32(UInt32(stackOffset)) + le32(UInt32(context.count)) + le32(UInt32(contextOffset))
        streams.append((3, threads.count, out.add(threads)))

        let hostName = out.utf16(ChromiumMinidumpTests.hostPath)
        let frameworkName = out.utf16(ChromiumMinidumpTests.frameworkPath)
        let hostCV = out.codeView(uuid: ChromiumMinidumpTests.hostUUID, name: "cmux Chromium Host")
        let frameworkCV = out.codeView(uuid: ChromiumMinidumpTests.frameworkUUID, name: "Chromium Embedded Framework")
        var modules = le32(2)
        modules += module(base: ChromiumMinidumpTests.hostBase, size: 0x10000, name: hostName, codeView: hostCV)
        modules += module(base: ChromiumMinidumpTests.frameworkBase, size: 0x100000, name: frameworkName, codeView: frameworkCV)
        streams.append((4, modules.count, out.add(modules)))

        // MINIDUMP_EXCEPTION_STREAM: thread 7, EXC_BAD_ACCESS recovered from EXC_CRASH, whose code holds SIGSEGV.
        var exception = le32(7) + le32(0) + le32(1) + le32(1) + le64(0) + le64(ChromiumMinidumpTests.frameworkBase + 0x1234)
            + le32(3) + le32(0)
        let information: [UInt64] = [10, UInt64(SIGSEGV) << 24 | 1, 0] + [UInt64](repeating: 0, count: 12)
        exception += information.flatMap(le64) + le32(UInt32(context.count)) + le32(UInt32(contextOffset))
        streams.append((6, exception.count, out.add(exception)))

        let misc = le32(24) + le32(1) + le32(4242) + le32(0) + le32(0) + le32(0)
        streams.append((15, misc.count, out.add(misc)))

        let simple = out.dictionary([("ptype", processType), ("url-chunk", "https://secret.example/private")])
        let objects = out.annotations([("pid", "4242"), ("title", "Secret Page Title"), ("top-origin", "https://secret.example")])
        let moduleInfo = le32(1) + le32(0) + le32(0) + le32(0) + le32(0) + le32(UInt32(objects.size)) + le32(UInt32(objects.offset))
        let moduleInfoOffset = out.add(moduleInfo)
        let moduleList = le32(1) + le32(1) + le32(UInt32(moduleInfo.count)) + le32(UInt32(moduleInfoOffset))
        let moduleListOffset = out.add(moduleList)
        let reportID: [UInt8] = [0xDD, 0xCC, 0xBB, 0xAA, 0x22, 0x11, 0x44, 0x33, 0x55, 0x66, 0x77, 0x88, 0x99, 0x00, 0xEE, 0xFF]
        let crashpadInfo = le32(1) + reportID + [UInt8](repeating: 0, count: 16) + le32(UInt32(simple.size))
            + le32(UInt32(simple.offset)) + le32(UInt32(moduleList.count)) + le32(UInt32(moduleListOffset)) + le32(0) + le64(0)
        streams.append((0x4350_0001, crashpadInfo.count, out.add(crashpadInfo)))

        var file = le32(0x504D_444D) + le32(0xA793) + le32(UInt32(streams.count)) + le32(32) + le32(0) + le32(0) + le64(0)
        for (type, size, offset) in streams {
            file += le32(type) + le32(UInt32(size)) + le32(UInt32(offset))
        }
        return Data(file + out.bytes)
    }

    /// A thin arm64 Mach-O header with one `LC_UUID`.
    static func machHeader(uuid: String, subtype: UInt32) -> [UInt8] {
        le32(0xFEED_FACF) + le32(0x0100_000C) + le32(subtype) + le32(6) + le32(1) + le32(24) + le32(0) + le32(0)
            + le32(0x1B) + le32(24) + uuidBytes(uuid)
    }

    static func module(base: UInt64, size: UInt32, name: Int, codeView: (offset: Int, size: Int)) -> [UInt8] {
        le64(base) + le32(size) + le32(0) + le32(0) + le32(UInt32(name)) + [UInt8](repeating: 0, count: 52)
            + le32(UInt32(codeView.size)) + le32(UInt32(codeView.offset)) + le32(0) + le32(0) + le64(0) + le64(0)
    }

    static func uuidBytes(_ uuid: String) -> [UInt8] {
        let hex = Array(uuid.filter { $0 != "-" })
        return stride(from: 0, to: hex.count, by: 2).map { UInt8(String(hex[$0...($0 + 1)]), radix: 16) ?? 0 }
    }

    static func le32(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) } }
    static func le16(_ value: UInt16) -> [UInt8] { (0..<2).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) } }
    static func le64(_ value: UInt64) -> [UInt8] { (0..<8).map { UInt8(truncatingIfNeeded: value >> (8 * UInt64($0))) } }

    static func put(_ bytes: inout [UInt8], _ offset: Int, _ values: [UInt64]) {
        for (index, value) in values.enumerated() {
            bytes.replaceSubrange((offset + index * 8)..<(offset + index * 8 + 8), with: le64(value))
        }
    }

    static func put32(_ bytes: inout [UInt8], _ offset: Int, _ value: UInt32) {
        bytes.replaceSubrange(offset..<(offset + 4), with: le32(value))
    }

    /// The blobs after the header and the stream directory, each 4-byte aligned.
    struct Writer {
        let base: Int
        var bytes: [UInt8] = []

        mutating func add(_ data: [UInt8]) -> Int {
            while (base + bytes.count) % 4 != 0 { bytes.append(0) }
            let offset = base + bytes.count
            bytes += data
            return offset
        }

        mutating func utf8(_ text: String) -> Int {
            add(le32(UInt32(text.utf8.count)) + Array(text.utf8) + [0])
        }

        mutating func utf16(_ text: String) -> Int {
            let units = Array(text.utf16)
            return add(le32(UInt32(units.count * 2)) + units.flatMap(le16) + [0, 0])
        }

        mutating func codeView(uuid: String, name: String) -> (offset: Int, size: Int) {
            let raw = uuidBytes(uuid)
            // crashpad::UUID: the first three fields little-endian.
            let guid = Array(raw[0..<4].reversed()) + Array(raw[4..<6].reversed()) + Array(raw[6..<8].reversed()) + Array(raw[8..<16])
            let record = Array("RSDS".utf8) + guid + le32(0) + Array(name.utf8) + [0]
            return (add(record), record.count)
        }

        mutating func dictionary(_ entries: [(String, String)]) -> (offset: Int, size: Int) {
            let pairs = entries.map { (utf8($0.0), utf8($0.1)) }
            let data = le32(UInt32(pairs.count)) + pairs.flatMap { le32(UInt32($0.0)) + le32(UInt32($0.1)) }
            return (add(data), data.count)
        }

        mutating func annotations(_ entries: [(String, String)]) -> (offset: Int, size: Int) {
            let records = entries.map { entry -> (Int, Int) in
                let name = utf8(entry.0)
                let value = add(le32(UInt32(entry.1.utf8.count)) + Array(entry.1.utf8))
                return (name, value)
            }
            let data = le32(UInt32(records.count))
                + records.flatMap { le32(UInt32($0.0)) + le16(1) + le16(0) + le32(UInt32($0.1)) }
            return (add(data), data.count)
        }
    }
}
