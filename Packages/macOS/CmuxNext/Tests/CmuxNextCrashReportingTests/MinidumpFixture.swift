import Foundation

/// A small Crashpad-shaped minidump for the redaction tests (p09-observability-105): a renderer of `pid` with one
/// thread whose stack holds a page address, a module with a home-folder path, Crashpad's process annotations and
/// Chromium's crash keys, a planted URL in each annotation kind, and a `__crash_info` style message stream.
/// Layouts: Crashpad's compat/non_win/dbghelp.h and minidump/minidump_extensions.h.
struct MinidumpFixture {
    static let stackSecret = "https://stack-secret.example/inbox"
    static let plantedURL = "https://planted.example/private?q=1"
    static let homePath = "/Users/alice/Applications/cmux NEXT.app/Contents/Frameworks/cmux NEXT Helper (Renderer).app/Contents/MacOS/cmux NEXT Helper (Renderer)"
    static let helperName = "cmux NEXT Helper (Renderer)"
    static let crashInfoMessage = "abort: page https://crash-info.example/ failed"

    var pid: Int32 = 4242
    var timeStamp: UInt32 = 1_790_000_000
    var processType = "renderer"
    var mainModulePath = Self.homePath
    /// The exception stream's code: 1 is EXC_BAD_ACCESS; ``ChromiumMinidump/simulatedExceptionCode`` a dump
    /// written without a crash.
    var exceptionCode: UInt32 = 1
    /// The `ver` annotation (write-crash-reporter-cfg.sh's ProductVersion).
    var ver = "0.62.0+4711 cef154.0.8037.98-30"

    /// Where the helper module is loaded, and the crashing thread's pc and (pointer-signed) lr inside it.
    static let moduleBase: UInt64 = 0x1_0000_0000
    static let crashPC: UInt64 = 0x1_0000_1234
    static let crashLR: UInt64 = 0x1_0000_0100
    static let signedLR: UInt64 = 0x002A_0001_0000_0100
    /// The module's CodeView GUID bytes (all 0xAB) as a debug id.
    static let debugID = "abababab-abab-abab-abab-abababababab"

    private var bytes: [UInt8] = []

    /// The dump's bytes.
    mutating func data() -> Data {
        bytes = [UInt8](repeating: 0, count: 32)  // header, written last
        let streamCount = 7
        let directory = reserve(streamCount * 12)

        // Thread list: one thread, its context, and its stack memory (in a memory list stream).
        let stack = append(Array(("....." + Self.stackSecret + ".....").utf8))
        // A MinidumpContextARM64: flags, cpsr and x0-x28 filled with 0xC7, then fp, lr (x30), sp and pc.
        let contextSize = 272
        let context = append([UInt8](repeating: 0xC7, count: contextSize))
        put32(context, 0x0040_0002)
        put64(context + 240, 0)
        put64(context + 248, Self.signedLR)
        put64(context + 256, 0x7000_0100)
        put64(context + 264, Self.crashPC)
        let threads = reserve(4 + 48)
        put32(threads, 1)
        put32(threads + 4, 7)  // ThreadId
        put64(threads + 4 + 24, 0x7000_0000)  // Stack.StartOfMemoryRange
        put32(threads + 4 + 32, UInt32(Self.stackSecret.utf8.count + 10))
        put32(threads + 4 + 36, UInt32(stack))
        put32(threads + 4 + 40, UInt32(contextSize))
        put32(threads + 4 + 44, UInt32(context))
        let memoryList = reserve(4 + 16)
        put32(memoryList, 1)
        put64(memoryList + 4, 0x7000_0000)
        put32(memoryList + 12, UInt32(Self.stackSecret.utf8.count + 10))
        put32(memoryList + 16, UInt32(stack))

        // Module list: the helper, with its path in the name and the CodeView record.
        let name = appendUTF16String(mainModulePath)
        var codeView: [UInt8] = Array("RSDS".utf8) + [UInt8](repeating: 0xAB, count: 16) + [1, 0, 0, 0]
        codeView += Array(mainModulePath.utf8) + [0]
        let cv = append(codeView)
        let modules = reserve(4 + 108)
        put32(modules, 1)
        put64(modules + 4, Self.moduleBase)
        put32(modules + 4 + 8, 0x4000)
        put32(modules + 4 + 20, UInt32(name))
        put32(modules + 4 + 76, UInt32(codeView.count))
        put32(modules + 4 + 80, UInt32(cv))

        // Exception stream.
        let exception = reserve(168)
        put32(exception, 7)
        put32(exception + 8, exceptionCode)
        put32(exception + 160, UInt32(contextSize))
        put32(exception + 164, UInt32(context))

        // Misc info: the pid.
        let misc = reserve(24)
        put32(misc, 24)
        put32(misc + 4, 1)  // MINIDUMP_MISC1_PROCESS_ID
        put32(misc + 8, UInt32(bitPattern: pid))

        // A Crashpad-only message stream that nothing allowlists.
        let message = append(Array(Self.crashInfoMessage.utf8))

        // Crashpad info: process simple annotations and one module's crash keys and list annotations.
        let simple = dictionary([("prod", "cmux-next"), ("ver", ver), ("url", Self.plantedURL),
                                 ("plat", "OS X")])
        let objects = annotationList([("ptype", processType), ("url-chunk-1-of-1", Self.plantedURL), ("osarch", "arm64")])
        let listText = appendUTF8String(Self.plantedURL)
        let list = reserve(8)
        put32(list, 1)
        put32(list + 4, UInt32(listText))
        let moduleInfo = reserve(28)
        put32(moduleInfo, 1)
        put32(moduleInfo + 4, 8)
        put32(moduleInfo + 8, UInt32(list))
        put32(moduleInfo + 20, objects.size)
        put32(moduleInfo + 24, objects.rva)
        let links = reserve(4 + 12)
        put32(links, 1)
        put32(links + 8, 28)
        put32(links + 12, UInt32(moduleInfo))
        let crashpad = reserve(64)
        put32(crashpad, 1)
        for offset in 4..<20 { bytes[crashpad + offset] = 0x11 }  // report_id
        for offset in 20..<36 { bytes[crashpad + offset] = 0x5A }  // client_id
        put32(crashpad + 36, simple.size)
        put32(crashpad + 40, simple.rva)
        put32(crashpad + 44, 16)
        put32(crashpad + 48, UInt32(links))
        put64(crashpad + 56, 0x0000_7FFF_FFFF_FFFF)

        let streams: [(UInt32, Int, Int)] = [(3, threads, 52), (5, memoryList, 20), (4, modules, 112), (6, exception, 168),
                                             (15, misc, 24), (0x4350_0002, message, Self.crashInfoMessage.utf8.count),
                                             (0x4350_0001, crashpad, 64)]
        precondition(streams.count == streamCount)
        for (index, stream) in streams.enumerated() {
            put32(directory + index * 12, stream.0)
            put32(directory + index * 12 + 4, UInt32(stream.2))
            put32(directory + index * 12 + 8, UInt32(stream.1))
        }
        put32(0, 0x504D_444D)
        put32(4, 0xA793)
        put32(8, UInt32(streamCount))
        put32(12, UInt32(directory))
        put32(20, timeStamp)
        return Data(bytes)
    }

    // MARK: Builders

    private mutating func reserve(_ count: Int) -> Int {
        let offset = bytes.count
        bytes += [UInt8](repeating: 0, count: count)
        return offset
    }

    private mutating func append(_ data: [UInt8]) -> Int {
        let offset = bytes.count
        bytes += data
        while bytes.count % 4 != 0 { bytes.append(0) }
        return offset
    }

    private mutating func appendUTF8String(_ text: String) -> Int {
        let utf8 = Array(text.utf8)
        return append(le32(UInt32(utf8.count)) + utf8 + [0])
    }

    private mutating func appendUTF16String(_ text: String) -> Int {
        let units = Array(text.utf16)
        var encoded = le32(UInt32(units.count * 2))
        for unit in units { encoded += [UInt8(truncatingIfNeeded: unit), UInt8(truncatingIfNeeded: unit >> 8)] }
        return append(encoded + [0, 0])
    }

    /// A `MinidumpSimpleStringDictionary`; its location descriptor's size and address.
    private mutating func dictionary(_ entries: [(String, String)]) -> (size: UInt32, rva: UInt32) {
        let strings = entries.map { (appendUTF8String($0.0), appendUTF8String($0.1)) }
        let rva = reserve(4 + entries.count * 8)
        put32(rva, UInt32(entries.count))
        for (index, pair) in strings.enumerated() {
            put32(rva + 4 + index * 8, UInt32(pair.0))
            put32(rva + 8 + index * 8, UInt32(pair.1))
        }
        return (UInt32(4 + entries.count * 8), UInt32(rva))
    }

    /// A `MinidumpAnnotationList` of string annotations.
    private mutating func annotationList(_ entries: [(String, String)]) -> (size: UInt32, rva: UInt32) {
        let parts = entries.map { entry -> (Int, Int) in
            let name = appendUTF8String(entry.0)
            let value = Array(entry.1.utf8)
            return (name, append(le32(UInt32(value.count)) + value))
        }
        let rva = reserve(4 + entries.count * 12)
        put32(rva, UInt32(entries.count))
        for (index, part) in parts.enumerated() {
            put32(rva + 4 + index * 12, UInt32(part.0))
            bytes[rva + 4 + index * 12 + 4] = 1  // kString
            put32(rva + 4 + index * 12 + 8, UInt32(part.1))
        }
        return (UInt32(4 + entries.count * 12), UInt32(rva))
    }

    private func le32(_ value: UInt32) -> [UInt8] {
        (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * UInt32($0))) }
    }

    private mutating func put32(_ offset: Int, _ value: UInt32) {
        for index in 0..<4 { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * UInt32(index))) }
    }

    private mutating func put64(_ offset: Int, _ value: UInt64) {
        for index in 0..<8 { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * UInt64(index))) }
    }
}

extension Data {
    /// Whether `text`'s UTF-8 or UTF-16LE bytes occur in the data.
    func containsText(_ text: String) -> Bool {
        let utf8 = Data(text.utf8)
        var utf16 = Data()
        for unit in text.utf16 { utf16.append(contentsOf: [UInt8(truncatingIfNeeded: unit), UInt8(truncatingIfNeeded: unit >> 8)]) }
        return range(of: utf8) != nil || range(of: utf16) != nil
    }
}
