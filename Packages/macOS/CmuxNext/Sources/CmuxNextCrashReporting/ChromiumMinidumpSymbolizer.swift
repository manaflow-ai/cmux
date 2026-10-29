import CmuxNextCompat
public import CmuxNextWakeups
public import Foundation

/// Names the functions of a Chromium dump's frames for `debug.crashes` and the crash report folder
/// (p01-process task 226), with `atos` on the image each frame lies in, as macOS's crash reporter
/// names an `.ips` report's frames. Only an image whose file on disk has the dump's `LC_UUID` is
/// read: a rebuilt image would name the wrong functions. An image macOS keeps only in the dyld shared
/// cache (no file) goes to `atos` by path, which reads the cache. Sentry symbolicates the same frames
/// itself from the uploaded debug files; this is for the local report.
public nonisolated struct ChromiumMinidumpSymbolizer: Sendable {
    /// One `atos` run: the frames of one image.
    public struct Job: Sendable, Equatable {
        public var path: String
        /// `atos -arch`: `arm64`, `arm64e` or `x86_64`.
        public var arch: String
        public var base: UInt64
        /// Indices into the dump's stack.
        public var frames: [Int]
        /// The address `atos` looks up for each frame: a return address minus one, so a call at the end
        /// of a function names that function (Breakpad and Sentry do the same).
        public var addresses: [UInt64]

        public init(path: String, arch: String, base: UInt64, frames: [Int], addresses: [UInt64]) {
            self.path = path
            self.arch = arch
            self.base = base
            self.frames = frames
            self.addresses = addresses
        }

        /// The `atos` arguments.
        public var arguments: [String] {
            ["-o", path, "-arch", arch, "-l", "0x" + String(base, radix: 16)] + addresses.map { "0x" + String($0, radix: 16) }
        }
    }

    let processes: any ProcessRunning
    /// The Mach-O slices of an image's file (``MachOSlice/read(_:)``); empty when there is no file.
    let slices: @Sendable (URL) -> [MachOSlice]

    /// - Parameters:
    ///   - processes: Runs `atos`.
    ///   - slices: Reads an image's slices from disk; tests pass their own.
    public init(processes: any ProcessRunning = AsyncProcess(),
                slices: @escaping @Sendable (URL) -> [MachOSlice] = { MachOSlice.read($0) }) {
        self.processes = processes
        self.slices = slices
    }

    /// The `atos` runs for `report`'s frames. Blocking (reads each image's load commands): on a files lane.
    public func jobs(for report: ChromiumMinidumpReport) -> [Job] {
        let dump = report.dump
        var byModule: [Int: [Int]] = [:]
        for (index, address) in dump.stack.enumerated() {
            guard let module = dump.modules.firstIndex(where: { $0.contains(address) }) else { continue }
            byModule[module, default: []].append(index)
        }
        return byModule.keys.sorted().compactMap { module -> Job? in
            let image = dump.modules[module]
            guard !image.path.isEmpty, let architecture = self.arch(of: image, in: dump) else { return nil }
            let frames = byModule[module] ?? []
            let addresses = frames.map { $0 == 0 ? dump.stack[$0] : dump.stack[$0] &- 1 }
            return Job(path: image.path, arch: architecture, base: image.base, frames: frames, addresses: addresses)
        }
    }

    /// The `atos -arch` of `image`: its slice whose `LC_UUID` is the dump's, or for an image with no file
    /// (one in the dyld shared cache) the system's own architecture. Nil when the file on disk is
    /// another build.
    func arch(of image: ChromiumMinidump.Module, in dump: ChromiumMinidump) -> String? {
        let found = self.slices(URL(fileURLWithPath: image.path))
        if found.isEmpty {
            guard image.path.hasPrefix("/usr/lib/") || image.path.hasPrefix("/System/") else { return nil }
            return switch dump.architecture {
            case .arm64: "arm64e"
            case .x86_64: "x86_64"
            case nil: nil
            }
        }
        return found.first { !image.uuid.isEmpty && $0.uuid == image.uuid }?.arch
    }

    /// The function of each frame of `report`, from `jobs` (``jobs(for:)``); nil where `atos` found none
    /// or did not run.
    public func symbols(for report: ChromiumMinidumpReport, jobs: [Job]) async -> [String?] {
        var symbols = [String?](repeating: nil, count: report.dump.stack.count)
        for job in jobs {
            let request = ProcessRequest(URL(fileURLWithPath: "/usr/bin/atos"), job.arguments, timeout: .seconds(20),
                                         priority: .bestEffort)
            guard let outcome = try? await processes.outcome(of: request), outcome.succeeded else { continue }
            let lines = outcome.text.split(separator: "\n", omittingEmptySubsequences: false)
            for (position, frame) in job.frames.enumerated() where position < lines.count && frame < symbols.count {
                symbols[frame] = Self.symbol(fromAtosLine: lines[position])
            }
        }
        return symbols
    }

    /// The function in one line of `atos` output (`name (in image) (file.cc:12)` gives
    /// `name (file.cc:12)`), or nil when `atos` printed the address back.
    static func symbol(fromAtosLine line: Substring) -> String? {
        let text = line.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !text.hasPrefix("0x") else { return nil }
        guard let start = text.range(of: " (in "), let end = text[start.upperBound...].firstIndex(of: ")") else {
            return text
        }
        return (text[..<start.lowerBound] + text[text.index(after: end)...]).trimmingCharacters(in: .whitespaces)
    }
}

/// One architecture slice of a Mach-O file: its `LC_UUID` and the `atos -arch` name of its CPU.
public nonisolated struct MachOSlice: Sendable, Equatable {
    /// Lowercase with dashes.
    public var uuid: String
    public var arch: String

    public init(uuid: String, arch: String) {
        self.uuid = uuid
        self.arch = arch
    }

    /// How much of a slice's start is read: the Mach-O header and its load commands.
    static let headerBytes = 64 << 10

    /// The slices of the Mach-O file at `url` (thin, fat or fat64); empty when it is missing or not
    /// Mach-O. Blocking: on a files lane.
    public static func read(_ url: URL) -> [MachOSlice] {
        guard let handle = try? blockingCall(.fileIO, { () throws -> FileHandle in try FileHandle(forReadingFrom: url) }) else {
            return []
        }
        defer { try? handle.close() }
        guard let start = try? handle.blockingRead(upToCount: headerBytes) else { return [] }
        let bytes = [UInt8](start)
        if let thin = slice(bytes) { return [thin] }
        return fatOffsets(bytes).compactMap { offset in
            guard (try? handle.blockingSeek(toOffset: offset)) != nil,
                  let header = try? handle.blockingRead(upToCount: headerBytes) else { return nil }
            return slice([UInt8](header))
        }
    }

    /// The slice offsets of a fat header (`FAT_MAGIC` 0xcafebabe or `FAT_MAGIC_64` 0xcafebabf, big-endian).
    static func fatOffsets(_ bytes: [UInt8]) -> [UInt64] {
        func big(_ offset: Int, _ count: Int) -> UInt64? {
            guard offset >= 0, offset + count <= bytes.count else { return nil }
            return bytes[offset..<(offset + count)].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        }
        guard let magic = big(0, 4), magic == 0xCAFE_BABE || magic == 0xCAFE_BABF, let count = big(4, 4) else { return [] }
        let wide = magic == 0xCAFE_BABF
        let entry = wide ? 32 : 20
        return (0..<min(Int(count), 64)).compactMap { index in
            let base = 8 + index * entry
            return wide ? big(base + 8, 8) : big(base + 8, 4)
        }
    }

    /// A thin 64-bit Mach-O header (`MH_MAGIC_64`, little-endian) and its `LC_UUID`, or nil.
    static func slice(_ bytes: [UInt8]) -> MachOSlice? {
        let file = MinidumpBytes(bytes: bytes)
        guard file.u32(0) == 0xFEED_FACF, let cpu = file.u32(4), let subtype = file.u32(8), let count = file.u32(16) else {
            return nil
        }
        let arch: String
        switch cpu {
        case 0x0100_000C: arch = subtype & 0xFF == 2 ? "arm64e" : "arm64"
        case 0x0100_0007: arch = "x86_64"
        default: return nil
        }
        var command = 32
        for _ in 0..<min(Int(count), 4096) {
            guard let kind = file.u32(command), let size = file.u32(command + 4), size >= 8 else { return nil }
            if kind == 0x1B, size >= 24 {  // LC_UUID
                return file.machUUID(command + 8).map { MachOSlice(uuid: $0, arch: arch) }
            }
            command += Int(size)
        }
        return nil
    }
}

extension MinidumpBytes {
    /// An `LC_UUID`'s 16 bytes in file order, lowercase with dashes.
    func machUUID(_ offset: Int) -> String? {
        guard offset >= 0, offset + 16 <= bytes.count else { return nil }
        let hex = bytes[offset..<(offset + 16)].map { Self.hex(UInt64($0), digits: 2) }
        return [hex[0..<4], hex[4..<6], hex[6..<8], hex[8..<10], hex[10..<16]].map { $0.joined() }.joined(separator: "-")
    }
}
