import Foundation

/// One pass over a dump's bytes for ``ChromiumMinidump``: marks what is kept, rewrites the kept structures in place,
/// zeroes the rest. Layouts: Crashpad's compat/non_win/dbghelp.h (packed to 4) and minidump_extensions.h.
nonisolated struct MinidumpRedactor {
    var bytes: [UInt8]
    let allowed: Set<String>
    /// One flag per byte: whether it stays.
    var keep: [Bool]
    var processID: Int32?
    var timeStamp: UInt32 = 0
    var mainModule: String?
    var annotations: [String: String] = [:]
    /// The exception stream's `ExceptionCode` (on macOS the Mach exception, or Crashpad's simulated-dump code).
    var exceptionCode: UInt32?
    /// The crashing thread's program counter and link register, from the exception stream's context.
    var crashPC: UInt64?
    var crashLR: UInt64?
    /// Each module's file name, load address, size and debug id, in list order.
    var modules: [ChromiumMinidump.Module] = []
    /// `MinidumpCrashpadInfo.address_mask`: the address bits of a signed (arm64e) pointer; 0 when absent.
    var addressMask: UInt64 = 0

    static let signature: UInt32 = 0x504D_444D  // "MDMP"
    static let headerSize = 32
    static let directoryEntrySize = 12
    static let threadSize = 48
    static let moduleSize = 108
    static let exceptionStreamSize = 168
    static let systemInfoSize = 56
    static let threadNameSize = 12
    /// `MinidumpCrashpadInfo` up to `module_list`; `reserved` and `address_mask` (arm64e pointer bits) follow in 64 bytes.
    static let crashpadInfoSize = 52
    static let crashpadInfoFullSize = 64
    static let moduleLinkSize = 12
    static let annotationSize = 12
    /// crashpad::Annotation::Type::kString.
    static let stringAnnotation: UInt16 = 1
    /// `CodeViewRecordPDB70`'s signature, "RSDS".
    static let codeViewPDB70: UInt32 = 0x5344_5352
    /// `MinidumpContextARM64` (minidump_context.h): flags, `pc` after `x0`-`x30` and `sp`, `lr` is `x30`.
    static let contextARM64: UInt32 = 0x0040_0000
    static let arm64PC = 264, arm64LR = 248
    /// `MinidumpContextAMD64`: `rip`.
    static let contextAMD64: UInt32 = 0x0010_0000
    static let amd64PC = 248

    // Stream types (dbghelp.h MINIDUMP_STREAM_TYPE, minidump_extensions.h).
    static let threadListStream: UInt32 = 3
    static let moduleListStream: UInt32 = 4
    static let exceptionStream: UInt32 = 6
    static let systemInfoStream: UInt32 = 7
    static let miscInfoStream: UInt32 = 15
    static let memoryInfoListStream: UInt32 = 16
    static let threadNameListStream: UInt32 = 24
    static let crashpadInfoStream: UInt32 = 0x4350_0001

    init(bytes: [UInt8], allowed: Set<String>) throws(ChromiumMinidump.Failure) {
        self.bytes = bytes
        self.allowed = allowed
        keep = [Bool](repeating: false, count: bytes.count)
        guard bytes.count >= Self.headerSize, try u32(0) == Self.signature else { throw .notMinidump }
    }

    mutating func redact() throws(ChromiumMinidump.Failure) {
        try mark(0, Self.headerSize)
        timeStamp = try u32(20)
        let count = try Int(u32(8))
        let directory = try Int(u32(12))
        try mark(directory, size(count, Self.directoryEntrySize))
        for index in 0..<count {
            let entry = directory + index * Self.directoryEntrySize
            let type = try u32(entry)
            let length = try Int(u32(entry + 4))
            let rva = try Int(u32(entry + 8))
            switch type {
            case Self.threadListStream: try keepThreads(at: rva)
            case Self.moduleListStream: try keepModules(at: rva)
            case Self.exceptionStream: try keepException(at: rva)
            case Self.systemInfoStream: try keepSystemInfo(at: rva)
            case Self.miscInfoStream: try keepMiscInfo(at: rva, length: length)
            case Self.memoryInfoListStream: try mark(rva, length)
            case Self.threadNameListStream: try keepThreadNames(at: rva)
            case Self.crashpadInfoStream: try keepCrashpadInfo(at: rva, length: length)
            default:
                // UnusedStream: the entry names nothing, and the stream's bytes are zeroed with the rest.
                try put32(entry, 0)
                try put32(entry + 4, 0)
                try put32(entry + 8, 0)
            }
        }
    }

    /// The kept bytes, every other byte zero.
    func output() -> [UInt8] {
        var out = bytes
        for index in out.indices where !keep[index] { out[index] = 0 }
        return out
    }

    // MARK: Streams

    /// `MINIDUMP_THREAD_LIST`: each thread's register context stays; its stack is left out (size and address 0).
    mutating func keepThreads(at rva: Int) throws(ChromiumMinidump.Failure) {
        let count = try Int(u32(rva))
        try mark(rva, 4 + size(count, Self.threadSize))
        for index in 0..<count {
            let thread = rva + 4 + index * Self.threadSize
            try put32(thread + 32, 0)  // Stack.Memory.DataSize
            try put32(thread + 36, 0)  // Stack.Memory.Rva
            try markLocation(thread + 40)  // ThreadContext
        }
    }

    /// `MINIDUMP_MODULE_LIST`: names and CodeView file names cut to file names; the first module is the executable.
    mutating func keepModules(at rva: Int) throws(ChromiumMinidump.Failure) {
        let count = try Int(u32(rva))
        try mark(rva, 4 + size(count, Self.moduleSize))
        for index in 0..<count {
            let module = rva + 4 + index * Self.moduleSize
            let name = try keepUTF16FileName(at: Int(u32(module + 20)))
            if index == 0 { mainModule = name }
            let base = try u64(module), imageSize = try u32(module + 8), debugID = try codeViewUUID(location: module + 76)
            modules.append(ChromiumMinidump.Module(name: name ?? "", base: base, size: imageSize, debugID: debugID))
            try keepCodeView(location: module + 76)
            // MiscRecord (IMAGE_DEBUG_MISC) can name a path; Crashpad writes none on macOS. Not kept.
            try put32(module + 84, 0)
            try put32(module + 88, 0)
        }
    }

    /// `MINIDUMP_EXCEPTION_STREAM` and the crashing thread's context.
    mutating func keepException(at rva: Int) throws(ChromiumMinidump.Failure) {
        try mark(rva, Self.exceptionStreamSize)
        exceptionCode = try u32(rva + 8)
        try markLocation(rva + 160)
        try readCrashContext(size: Int(u32(rva + 160)), at: Int(u32(rva + 164)))
    }

    /// The crashing thread's program counter (and, on arm64, link register) from its CPU context.
    mutating func readCrashContext(size: Int, at rva: Int) throws(ChromiumMinidump.Failure) {
        guard rva != 0, size >= 4 else { return }
        let flags = try u32(rva)
        if flags & Self.contextARM64 != 0, size >= Self.arm64PC + 8 {
            crashPC = try u64(rva + Self.arm64PC)
            crashLR = try u64(rva + Self.arm64LR)
        } else if flags & Self.contextAMD64 != 0, size >= Self.amd64PC + 8 {
            crashPC = try u64(rva + Self.amd64PC)
        }
    }

    /// `MINIDUMP_SYSTEM_INFO` and its OS build string.
    mutating func keepSystemInfo(at rva: Int) throws(ChromiumMinidump.Failure) {
        try mark(rva, Self.systemInfoSize)
        let csd = try Int(u32(rva + 24))
        if csd != 0 { try mark(csd, 4 + Int(u32(csd)) + 2) }
    }

    /// `MINIDUMP_MISC_INFO`: the process id when `MINIDUMP_MISC1_PROCESS_ID` is set.
    mutating func keepMiscInfo(at rva: Int, length: Int) throws(ChromiumMinidump.Failure) {
        try mark(rva, length)
        guard length >= 12, try u32(rva + 4) & 1 != 0 else { return }
        processID = try Int32(bitPattern: u32(rva + 8))
    }

    /// `MINIDUMP_THREAD_NAME_LIST`: Chromium's thread names (`CrRendererMain`).
    mutating func keepThreadNames(at rva: Int) throws(ChromiumMinidump.Failure) {
        let count = try Int(u32(rva))
        try mark(rva, 4 + size(count, Self.threadNameSize))
        for index in 0..<count {
            let name = try Int(clamping: u64(rva + 4 + index * Self.threadNameSize + 4))
            if name != 0 { try mark(name, 4 + Int(u32(name)) + 2) }
        }
    }

    /// `MinidumpCrashpadInfo`: the process annotations and each module's, filtered; list annotations and the
    /// client id dropped.
    mutating func keepCrashpadInfo(at rva: Int, length: Int) throws(ChromiumMinidump.Failure) {
        // A shorter layout is not read: its bytes stay zero.
        guard length >= Self.crashpadInfoSize else { return }
        try mark(rva, min(length, Self.crashpadInfoFullSize))
        if length >= Self.crashpadInfoFullSize { addressMask = try u64(rva + 56) }
        // client_id: Crashpad's install-wide id, the same in every report of this Mac.
        for offset in 20..<36 { bytes[rva + offset] = 0 }
        try keepSimpleAnnotations(location: rva + 36)
        let listSize = try Int(u32(rva + 44))
        let list = try Int(u32(rva + 48))
        guard listSize > 0, list != 0 else { return }
        let count = try Int(u32(list))
        try mark(list, 4 + size(count, Self.moduleLinkSize))
        for index in 0..<count {
            let link = list + 4 + index * Self.moduleLinkSize
            let infoSize = try Int(u32(link + 4))
            let info = try Int(u32(link + 8))
            guard infoSize >= 12, info != 0 else { continue }
            try mark(info, min(infoSize, 28))
            // list_annotations: free text (abort and assertion messages), never kept.
            try put32(info + 4, 0)
            try put32(info + 8, 0)
            if infoSize >= 20 { try keepSimpleAnnotations(location: info + 12) }
            if infoSize >= 28 { try keepAnnotationObjects(location: info + 20) }
        }
    }

    // MARK: Annotations

    /// A `MinidumpSimpleStringDictionary` at the location descriptor `location`: allowlisted entries with plain
    /// values move to the front and the count shrinks to them; the others are not marked, so they are zeroed.
    mutating func keepSimpleAnnotations(location: Int) throws(ChromiumMinidump.Failure) {
        let dictionary = try Int(u32(location + 4))
        guard try u32(location) > 0, dictionary != 0 else { return }
        let count = try Int(u32(dictionary))
        _ = try size(count, 8)
        var kept = 0
        for index in 0..<count {
            let entry = dictionary + 4 + index * 8
            let key = try Int(u32(entry))
            let value = try Int(u32(entry + 4))
            guard let name = try utf8String(at: key), let text = try utf8String(at: value), allows(name, text) else { continue }
            try put32(dictionary + 4 + kept * 8, UInt32(key))
            try put32(dictionary + 4 + kept * 8 + 4, UInt32(value))
            try markUTF8String(at: key)
            try markUTF8String(at: value)
            annotations[name] = text
            kept += 1
        }
        try put32(dictionary, UInt32(kept))
        try put32(location, UInt32(4 + kept * 8))
        try mark(dictionary, 4 + kept * 8)
    }

    /// A `MinidumpAnnotationList` (crashpad::Annotation, Chromium's crash keys): allowlisted string annotations
    /// with plain values move to the front; the others are zeroed.
    mutating func keepAnnotationObjects(location: Int) throws(ChromiumMinidump.Failure) {
        let list = try Int(u32(location + 4))
        guard try u32(location) > 0, list != 0 else { return }
        let count = try Int(u32(list))
        _ = try size(count, Self.annotationSize)
        var kept = 0
        for index in 0..<count {
            let entry = list + 4 + index * Self.annotationSize
            let name = try Int(u32(entry))
            let type = try u16(entry + 4)
            let value = try Int(u32(entry + 8))
            guard type == Self.stringAnnotation, value != 0, let key = try utf8String(at: name) else { continue }
            let length = try Int(u32(value))
            try check(value + 4, length)
            let text = String(decoding: bytes[(value + 4)..<(value + 4 + length)], as: UTF8.self)
            guard allows(key, text) else { continue }
            let target = list + 4 + kept * Self.annotationSize
            if target != entry {
                for offset in 0..<Self.annotationSize { bytes[target + offset] = bytes[entry + offset] }
            }
            try markUTF8String(at: name)
            try mark(value, 4 + length)
            annotations[key] = text
            kept += 1
        }
        try put32(list, UInt32(kept))
        try put32(location, UInt32(4 + kept * Self.annotationSize))
        try mark(list, 4 + kept * Self.annotationSize)
    }

    func allows(_ name: String, _ value: String) -> Bool {
        allowed.contains(name) && ChromiumMinidump.isPlainValue(value)
    }

    // MARK: Strings

    /// A `MINIDUMP_STRING` (UTF-16LE, byte length first, two-byte terminator) cut in place to its file name.
    mutating func keepUTF16FileName(at rva: Int) throws(ChromiumMinidump.Failure) -> String? {
        guard rva != 0 else { return nil }
        let length = try Int(u32(rva))
        try check(rva + 4, length)
        var units: [UInt16] = []
        units.reserveCapacity(length / 2)
        for offset in stride(from: 0, to: length - 1, by: 2) {
            units.append(UInt16(bytes[rva + 4 + offset]) | UInt16(bytes[rva + 4 + offset + 1]) << 8)
        }
        let name = ChromiumMinidump.fileName(String(decoding: units, as: UTF16.self))
        let encoded = Array(name.utf16)
        // A file name is never longer than its path, so it and a terminator fit where the path and its terminator were.
        try check(rva + 4, encoded.count * 2 + 2)
        try put32(rva, UInt32(encoded.count * 2))
        for (index, unit) in encoded.enumerated() {
            bytes[rva + 4 + index * 2] = UInt8(truncatingIfNeeded: unit)
            bytes[rva + 4 + index * 2 + 1] = UInt8(truncatingIfNeeded: unit >> 8)
        }
        bytes[rva + 4 + encoded.count * 2] = 0
        bytes[rva + 4 + encoded.count * 2 + 1] = 0
        try mark(rva, 4 + encoded.count * 2 + 2)
        return name
    }

    /// A `CodeViewRecordPDB70` ("RSDS", GUID, age, then the NUL-terminated file name), with the file name cut to
    /// its last component. Another record kind may carry a path and is not kept.
    mutating func keepCodeView(location: Int) throws(ChromiumMinidump.Failure) {
        let length = try Int(u32(location))
        let rva = try Int(u32(location + 4))
        guard length > 24, rva != 0 else { return }
        try check(rva, length)
        guard try u32(rva) == Self.codeViewPDB70 else { return }
        let start = rva + 24, end = rva + length
        let terminator = bytes[start..<end].firstIndex(of: 0) ?? end
        let name = Array(ChromiumMinidump.fileName(String(decoding: bytes[start..<terminator], as: UTF8.self)).utf8)
        for (index, byte) in name.enumerated() { bytes[start + index] = byte }
        if start + name.count < end { bytes[start + name.count] = 0 }
        let kept = min(24 + name.count + 1, length)
        try put32(location, UInt32(kept))
        try mark(rva, kept)
    }

    /// The Mach-O UUID of a `CodeViewRecordPDB70` (Crashpad writes the UUID as its GUID, data fields
    /// little-endian), formatted as Sentry's debug id; nil for another record kind.
    func codeViewUUID(location: Int) throws(ChromiumMinidump.Failure) -> String? {
        let length = try Int(u32(location))
        let rva = try Int(u32(location + 4))
        guard length >= 24, rva != 0, try u32(rva) == Self.codeViewPDB70 else { return nil }
        let guid = rva + 4
        try check(guid, 16)
        let data1 = try u32(guid), data2 = try u16(guid + 4), data3 = try u16(guid + 6)
        let tail = bytes[(guid + 8)..<(guid + 16)].map { String(format: "%02x", $0) }
        return String(format: "%08x-%04x-%04x-", data1, data2, data3) + tail[0..<2].joined() + "-" + tail[2...].joined()
    }

    /// A `MinidumpUTF8String`'s text, nil at address 0.
    func utf8String(at rva: Int) throws(ChromiumMinidump.Failure) -> String? {
        guard rva != 0 else { return nil }
        let length = try Int(u32(rva))
        try check(rva + 4, length)
        return String(decoding: bytes[(rva + 4)..<(rva + 4 + length)], as: UTF8.self)
    }

    /// Keeps a `MinidumpUTF8String`: the length, the text and its NUL when the file has it.
    mutating func markUTF8String(at rva: Int) throws(ChromiumMinidump.Failure) {
        let length = try Int(u32(rva))
        try mark(rva, 4 + length)
        if rva + 4 + length < bytes.count { keep[rva + 4 + length] = true }
    }

    // MARK: Bytes

    /// Keeps what the `MINIDUMP_LOCATION_DESCRIPTOR` at `location` points to.
    mutating func markLocation(_ location: Int) throws(ChromiumMinidump.Failure) {
        let length = try Int(u32(location))
        let rva = try Int(u32(location + 4))
        if length > 0, rva != 0 { try mark(rva, length) }
    }

    mutating func mark(_ offset: Int, _ length: Int) throws(ChromiumMinidump.Failure) {
        try check(offset, length)
        for index in offset..<(offset + length) { keep[index] = true }
    }

    func check(_ offset: Int, _ length: Int) throws(ChromiumMinidump.Failure) {
        guard offset >= 0, length >= 0, offset <= bytes.count, length <= bytes.count - offset else {
            throw .truncated(offset: offset)
        }
    }

    /// `count * stride`, refused when it cannot fit in the file.
    func size(_ count: Int, _ stride: Int) throws(ChromiumMinidump.Failure) -> Int {
        guard count >= 0, count <= bytes.count / stride else { throw .truncated(offset: bytes.count) }
        return count * stride
    }

    func u16(_ offset: Int) throws(ChromiumMinidump.Failure) -> UInt16 {
        try check(offset, 2)
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    func u32(_ offset: Int) throws(ChromiumMinidump.Failure) -> UInt32 {
        try check(offset, 4)
        var value: UInt32 = 0
        for index in 0..<4 { value |= UInt32(bytes[offset + index]) << (8 * UInt32(index)) }
        return value
    }

    func u64(_ offset: Int) throws(ChromiumMinidump.Failure) -> UInt64 {
        try check(offset, 8)
        var value: UInt64 = 0
        for index in 0..<8 { value |= UInt64(bytes[offset + index]) << (8 * UInt64(index)) }
        return value
    }

    mutating func put32(_ offset: Int, _ value: UInt32) throws(ChromiumMinidump.Failure) {
        try check(offset, 4)
        for index in 0..<4 { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * UInt32(index))) }
    }
}
