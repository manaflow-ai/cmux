public import Foundation

/// What cmux reads from a Crashpad minidump of the Chromium Host or one of its helpers
/// (plans/cmux-next/chrome-parity/p01-process.md, task 226): the exception, the crashed thread's
/// stack walked by frame pointers, the loaded modules with their `LC_UUID`, and the annotations in
/// ``keptAnnotations``.
///
/// Every other annotation is dropped while the dump is read, never kept: Chromium writes the page's
/// URL into its crash keys (`url-chunk`, `top-origin`), so a dump's metadata would otherwise hold
/// page content. The dump file itself, which holds stack memory, never leaves Crashpad's database.
///
/// The layout is Breakpad's and Crashpad's minidump format
/// (third_party/crashpad/crashpad/minidump/minidump_extensions.h, dbghelp's `MINIDUMP_*`, packed to
/// 4 bytes); the stack walk is Breakpad's frame-pointer walk
/// (src/processor/stackwalker_arm64.cc, stackwalker_amd64.cc). macOS builds every image with frame
/// pointers, so the walk finds every caller but the one a leaf function has not saved yet.
public nonisolated struct ChromiumMinidump: Sendable, Equatable {
    /// One loaded image.
    public struct Module: Sendable, Equatable {
        public var base: UInt64
        public var size: UInt64
        /// The image's path as the dump names it. For symbolication only: a report keeps the file name.
        public var path: String
        /// The image's `LC_UUID`, lowercase with dashes, or empty when the dump has none.
        public var uuid: String

        public init(base: UInt64, size: UInt64, path: String, uuid: String) {
            self.base = base
            self.size = size
            self.path = path
            self.uuid = uuid
        }

        /// The path's last component.
        public var name: String { path.split(separator: "/").last.map(String.init) ?? path }

        func contains(_ address: UInt64) -> Bool { address >= base && address - base < size }
    }

    /// The crashed thread's CPU.
    public enum Architecture: String, Sendable, Equatable {
        case arm64
        case x86_64
    }

    /// The annotations a report keeps: the process type, the product and version, the platform and
    /// the pid. No other crash key is read out of a dump.
    public static let keptAnnotations: Set<String> = ["ptype", "pid", "product", "version", "platform", "channel",
                                                      "is-dump-process-without-crashing"]

    /// Crashpad's report id (the dump's file name without `.dmp`), lowercase with dashes.
    public var reportID: String?
    public var processID: UInt32?
    /// The Mach exception type (`EXC_BAD_ACCESS` = 1, ...), after Crashpad recovered the original
    /// exception from an `EXC_CRASH`.
    public var exceptionType: UInt32?
    public var exceptionAddress: UInt64?
    /// The signal that ended the process, from the `EXC_CRASH` code (bits 24-31), when the dump has it.
    public var signal: Int32?
    public var architecture: Architecture?
    /// The crashed thread's instruction addresses, innermost first: the program counter, then each
    /// return address.
    public var stack: [UInt64]
    public var modules: [Module]
    /// Only ``keptAnnotations``.
    public var annotations: [String: String]

    public init(reportID: String? = nil, processID: UInt32? = nil, exceptionType: UInt32? = nil,
                exceptionAddress: UInt64? = nil, signal: Int32? = nil, architecture: Architecture? = nil,
                stack: [UInt64] = [], modules: [Module] = [], annotations: [String: String] = [:]) {
        self.reportID = reportID
        self.processID = processID
        self.exceptionType = exceptionType
        self.exceptionAddress = exceptionAddress
        self.signal = signal
        self.architecture = architecture
        self.stack = stack
        self.modules = modules
        self.annotations = annotations
    }

    /// Why a file is not a minidump cmux can read.
    public enum ReadError: Error, Equatable {
        /// No `MDMP` signature.
        case notMinidump
        /// The header or the stream directory runs past the end of the file.
        case truncated
    }

    /// The most frames a walk returns.
    static let maxFrames = 256
    /// The most streams, modules or threads read from one dump.
    static let maxEntries = 16_384

    /// Reads a minidump. Streams it cannot read (cut off, an unknown CPU) leave their fields empty.
    public init(data: Data) throws(ReadError) {
        let file = MinidumpBytes(data)
        guard file.u32(0) == 0x504D_444D else { throw .notMinidump }  // "MDMP"
        guard let count = file.u32(8), let directory = file.u32(12) else { throw .truncated }
        var streams: [UInt32: MinidumpBytes.Location] = [:]
        for index in 0..<min(Int(count), Self.maxEntries) {
            let entry = Int(directory) + index * 12
            guard let type = file.u32(entry) else { throw .truncated }
            // A stream whose range runs past the end is left out; the others still read.
            guard let location = file.location(entry + 4) else { continue }
            if streams[type] == nil { streams[type] = location }
        }
        self.init()
        if let misc = streams[MinidumpBytes.Stream.miscInfo], let flags = file.u32(misc.offset + 4), flags & 1 != 0 {
            processID = file.u32(misc.offset + 8)
        }
        modules = streams[MinidumpBytes.Stream.moduleList].map { Self.modules(file, $0) } ?? []
        if let info = streams[MinidumpBytes.Stream.crashpadInfo] {
            reportID = file.crashpadUUID(info.offset + 4)
            annotations = Self.annotations(file, info)
        }
        guard let exception = streams[MinidumpBytes.Stream.exception] else { return }
        readException(file, exception, threads: streams[MinidumpBytes.Stream.threadList],
                      memory: streams[MinidumpBytes.Stream.memoryList],
                      addressMask: streams[MinidumpBytes.Stream.crashpadInfo].flatMap { $0.size >= 64 ? file.u64($0.offset + 56) : nil })
    }

    /// The exception, the crashed thread's registers and its walked stack.
    private mutating func readException(_ file: MinidumpBytes, _ stream: MinidumpBytes.Location,
                                        threads: MinidumpBytes.Location?, memory: MinidumpBytes.Location?,
                                        addressMask: UInt64?) {
        let base = stream.offset
        guard let threadID = file.u32(base), let code = file.u32(base + 8) else { return }
        exceptionType = code
        exceptionAddress = file.u64(base + 24)
        // Crashpad puts the raw exception first, then its codes (exception_snapshot_mac.cc): for EXC_CRASH
        // (10) the first code holds the signal in bits 24-31 (xnu's proc_prepareexit).
        if let parameters = file.u32(base + 32), parameters >= 2, file.u64(base + 40) == 10,
           let crashCode = file.u64(base + 48) {
            signal = Int32((crashCode >> 24) & 0xFF)
        }
        guard let context = file.location(base + 160) else { return }
        var regions = threads.map { Self.stackRegions(file, $0, thread: threadID) } ?? []
        regions += memory.map { Self.memoryRegions(file, $0) } ?? []
        // arm64 user addresses are 47 bits; Crashpad records the process's mask (pointer authentication bits).
        let mask = addressMask.flatMap { $0 == 0 ? nil : ~$0 } ?? 0x0000_7FFF_FFFF_FFFF
        guard let registers = Self.registers(file, context) else { return }
        architecture = registers.architecture
        stack = Self.walk(registers, mask: mask, read: { address in Self.read(file, regions, address) })
    }

    /// The registers a frame-pointer walk needs.
    struct Registers: Equatable {
        var architecture: Architecture
        var pc: UInt64
        var fp: UInt64
    }

    /// The registers of a `MinidumpContextARM64` (flag 0x00400000) or a `MinidumpContextAMD64`
    /// (flag 0x00100000 in `ContextFlags` at 48).
    static func registers(_ file: MinidumpBytes, _ context: MinidumpBytes.Location) -> Registers? {
        let base = context.offset
        if let flags = file.u32(base), flags & 0x0040_0000 != 0, context.size >= 272,
           let fp = file.u64(base + 8 + 29 * 8), let pc = file.u64(base + 264) {
            return Registers(architecture: .arm64, pc: pc, fp: fp)
        }
        if let flags = file.u32(base + 48), flags & 0x0010_0000 != 0, context.size >= 256,
           let rbp = file.u64(base + 160), let rip = file.u64(base + 248) {
            return Registers(architecture: .x86_64, pc: rip, fp: rbp)
        }
        return nil
    }

    /// The program counter, then the return address of each frame record: `[fp]` is the caller's frame
    /// pointer and `[fp + 8]` the return address, on arm64 and x86_64 alike. Stops at a null or
    /// unreadable record, or one that does not move up the stack.
    static func walk(_ registers: Registers, mask: UInt64, read: (UInt64) -> UInt64?) -> [UInt64] {
        var frames = [registers.pc & mask]
        var fp = registers.fp & mask
        while frames.count < maxFrames, fp != 0, fp % 8 == 0 {
            guard let caller = read(fp), let returnAddress = read(fp &+ 8).map({ $0 & mask }), returnAddress != 0 else {
                break
            }
            frames.append(returnAddress)
            let next = caller & mask
            guard next > fp else { break }
            fp = next
        }
        return frames
    }

    /// One readable range of the dead process's memory.
    struct Region: Equatable {
        var start: UInt64
        var size: UInt64
        var offset: Int
    }

    /// The crashed thread's stack (`MINIDUMP_THREAD`, 48 bytes, `Stack` at 24).
    static func stackRegions(_ file: MinidumpBytes, _ stream: MinidumpBytes.Location, thread: UInt32) -> [Region] {
        guard let first = file.listStart(stream, entrySize: 48) else { return [] }
        for index in 0..<min(first.count, maxEntries) {
            let entry = first.offset + index * 48
            guard file.u32(entry) == thread else { continue }
            guard let start = file.u64(entry + 24), let memory = file.location(entry + 32) else { return [] }
            return [Region(start: start, size: UInt64(memory.size), offset: memory.offset)]
        }
        return []
    }

    /// Every range of `MemoryListStream` (`MINIDUMP_MEMORY_DESCRIPTOR`, 16 bytes).
    static func memoryRegions(_ file: MinidumpBytes, _ stream: MinidumpBytes.Location) -> [Region] {
        guard let first = file.listStart(stream, entrySize: 16) else { return [] }
        return (0..<min(first.count, maxEntries)).compactMap { index in
            let entry = first.offset + index * 16
            guard let start = file.u64(entry), let memory = file.location(entry + 8) else { return nil }
            return Region(start: start, size: UInt64(memory.size), offset: memory.offset)
        }
    }

    static func read(_ file: MinidumpBytes, _ regions: [Region], _ address: UInt64) -> UInt64? {
        for region in regions where region.size >= 8 && address >= region.start && address - region.start <= region.size - 8 {
            return file.u64(region.offset + Int(address - region.start))
        }
        return nil
    }

    /// `MINIDUMP_MODULE` (108 bytes): base at 0, size at 8, name at 20, CodeView record at 76.
    static func modules(_ file: MinidumpBytes, _ stream: MinidumpBytes.Location) -> [Module] {
        guard let first = file.listStart(stream, entrySize: 108) else { return [] }
        return (0..<min(first.count, maxEntries)).compactMap { index in
            let entry = first.offset + index * 108
            guard let base = file.u64(entry), let size = file.u32(entry + 8), let name = file.u32(entry + 20) else {
                return nil
            }
            let uuid = file.location(entry + 76).flatMap { file.codeViewUUID($0) } ?? ""
            return Module(base: base, size: UInt64(size), path: file.utf16String(Int(name)) ?? "", uuid: uuid)
        }
    }

    /// The kept string annotations of `MinidumpCrashpadInfo`: the process's simple annotations (at 36),
    /// then each module's simple annotations and string annotation objects (the module list at 44).
    static func annotations(_ file: MinidumpBytes, _ stream: MinidumpBytes.Location) -> [String: String] {
        var kept: [String: String] = [:]
        func keep(_ name: String?, _ value: String?) {
            guard let name, let value, keptAnnotations.contains(name), kept[name] == nil else { return }
            kept[name] = value
        }
        if let simple = file.location(stream.offset + 36) {
            for (name, value) in file.simpleDictionary(simple) { keep(name, value) }
        }
        guard let list = file.location(stream.offset + 44), list.size >= 4, let count = file.u32(list.offset) else { return kept }
        for index in 0..<min(Int(count), (list.size - 4) / 12) {
            guard let info = file.location(list.offset + 4 + index * 12 + 4), info.size >= 28 else { continue }
            if let simple = file.location(info.offset + 12) {
                for (name, value) in file.simpleDictionary(simple) { keep(name, value) }
            }
            if let objects = file.location(info.offset + 20) {
                for (name, value) in file.stringAnnotations(objects) { keep(name, value) }
            }
        }
        return kept
    }
}

/// Little-endian reads of a minidump's bytes; every read is bounds-checked and returns nil past the end.
nonisolated struct MinidumpBytes {
    /// The stream types cmux reads (`MINIDUMP_STREAM_TYPE`, Crashpad's `kMinidumpStreamTypeCrashpadInfo`).
    enum Stream {
        static let threadList: UInt32 = 3
        static let moduleList: UInt32 = 4
        static let memoryList: UInt32 = 5
        static let exception: UInt32 = 6
        static let miscInfo: UInt32 = 15
        static let crashpadInfo: UInt32 = 0x4350_0001
    }

    /// A `MINIDUMP_LOCATION_DESCRIPTOR`: a size and an offset into the file.
    struct Location: Equatable {
        var size: Int
        var offset: Int
    }

    let bytes: [UInt8]

    init(_ data: Data) {
        bytes = [UInt8](data)
    }

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    func u8(_ offset: Int) -> UInt8? {
        offset >= 0 && offset < bytes.count ? bytes[offset] : nil
    }

    func u16(_ offset: Int) -> UInt16? {
        guard offset >= 0, offset <= bytes.count - 2 else { return nil }
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    func u32(_ offset: Int) -> UInt32? {
        guard offset >= 0, offset <= bytes.count - 4 else { return nil }
        return (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << (8 * UInt32($1)) }
    }

    func u64(_ offset: Int) -> UInt64? {
        guard offset >= 0, offset <= bytes.count - 8 else { return nil }
        return (0..<8).reduce(UInt64(0)) { $0 | UInt64(bytes[offset + $1]) << (8 * UInt64($1)) }
    }

    /// A location descriptor at `offset` whose range lies inside the file.
    func location(_ offset: Int) -> Location? {
        guard let size = u32(offset), let rva = u32(offset + 4) else { return nil }
        let location = Location(size: Int(size), offset: Int(rva))
        guard location.offset <= bytes.count, location.size <= bytes.count - location.offset else { return nil }
        return location
    }

    /// The first entry of a list stream (a 32-bit count, then the entries) and how many entries the stream
    /// holds. Some writers pad the count to 8 bytes; Breakpad's reader accepts both (minidump.cc), and so
    /// does this one.
    func listStart(_ stream: Location, entrySize: Int) -> (offset: Int, count: Int)? {
        guard stream.size >= 4, let count = u32(stream.offset).map(Int.init) else { return nil }
        let header = stream.size == 8 + count * entrySize ? 8 : 4
        return (stream.offset + header, min(count, (stream.size - header) / entrySize))
    }

    /// A `MINIDUMP_STRING`: a byte length, then UTF-16LE.
    func utf16String(_ offset: Int) -> String? {
        guard let length = u32(offset).map(Int.init), length % 2 == 0, length <= bytes.count - offset - 4 else {
            return nil
        }
        let units = stride(from: offset + 4, to: offset + 4 + length, by: 2).compactMap { u16($0) }
        return String(decoding: units, as: UTF16.self)
    }

    /// A `MinidumpUTF8String` at `offset`: a byte length, then the bytes.
    func utf8String(_ offset: Int) -> String? {
        guard let length = u32(offset).map(Int.init), offset + 4 <= bytes.count, length <= bytes.count - offset - 4 else {
            return nil
        }
        return String(decoding: bytes[(offset + 4)..<(offset + 4 + length)], as: UTF8.self)
    }

    /// A `MinidumpSimpleStringDictionary`: a count, then (key, value) pairs of `MinidumpUTF8String` offsets.
    /// An empty location (size 0: the writer had none) holds no entries.
    func simpleDictionary(_ location: Location) -> [(String?, String?)] {
        guard location.size >= 4, let count = u32(location.offset) else { return [] }
        return (0..<min(Int(count), (location.size - 4) / 8)).compactMap { index in
            let entry = location.offset + 4 + index * 8
            guard let key = u32(entry), let value = u32(entry + 4) else { return nil }
            return (utf8String(Int(key)), utf8String(Int(value)))
        }
    }

    /// The string entries of a `MinidumpAnnotationList`: a count, then (name, type, reserved, value)
    /// records of 12 bytes; a string annotation is type 1 (`crashpad::Annotation::Type::kString`), its
    /// value a `MinidumpByteArray`.
    func stringAnnotations(_ location: Location) -> [(String?, String?)] {
        guard location.size >= 4, let count = u32(location.offset) else { return [] }
        return (0..<min(Int(count), (location.size - 4) / 12)).compactMap { index in
            let entry = location.offset + 4 + index * 12
            guard let name = u32(entry), u16(entry + 4) == 1, let value = u32(entry + 8) else { return nil }
            return (utf8String(Int(name)), utf8String(Int(value)))
        }
    }

    /// The UUID of a `CodeViewRecordPDB70` (`RSDS`): Crashpad stores the Mach-O `LC_UUID` there as a GUID
    /// (`crashpad::UUID`, first three fields little-endian).
    func codeViewUUID(_ location: Location) -> String? {
        guard location.size >= 24, u32(location.offset) == 0x5344_5352 else { return nil }  // "RSDS"
        return crashpadUUID(location.offset + 4)
    }

    /// A `crashpad::UUID` at `offset` (a u32, two u16 little-endian, then 8 bytes), lowercase with dashes.
    func crashpadUUID(_ offset: Int) -> String? {
        guard let first = u32(offset), let second = u16(offset + 4), let third = u16(offset + 6),
              offset + 16 <= bytes.count else { return nil }
        let rest = bytes[(offset + 8)..<(offset + 16)].map { Self.hex(UInt64($0), digits: 2) }
        return [Self.hex(UInt64(first), digits: 8), Self.hex(UInt64(second), digits: 4), Self.hex(UInt64(third), digits: 4),
                rest[0..<2].joined(), rest[2..<8].joined()].joined(separator: "-")
    }

    static func hex(_ value: UInt64, digits: Int) -> String {
        let text = String(value, radix: 16)
        return String(repeating: "0", count: max(0, digits - text.count)) + text
    }
}
