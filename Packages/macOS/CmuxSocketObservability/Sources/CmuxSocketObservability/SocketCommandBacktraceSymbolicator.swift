import Darwin
import Foundation

/// Formats instruction addresses for watchdog unified-log records.
nonisolated struct SocketCommandBacktraceSymbolicator {
    static func symbolicate(_ addresses: [UInt]) -> [String] {
        addresses.enumerated().map { index, address in
            symbolLine(index: index, address: address)
        }
    }

    private static func symbolLine(index: Int, address: UInt) -> String {
        var info = Dl_info()
        guard let pointer = UnsafeRawPointer(bitPattern: address),
              dladdr(pointer, &info) != 0 else {
            return "\(index) <unknown> \(hexString(address))"
        }

        let image = info.dli_fname.map {
            URL(fileURLWithPath: String(cString: $0)).lastPathComponent
        } ?? "<unknown>"
        let symbol = info.dli_sname.map { String(cString: $0) } ?? "<unknown>"
        let symbolAddress = info.dli_saddr.map { UInt(bitPattern: $0) } ?? 0
        let offset = address >= symbolAddress ? address - symbolAddress : 0
        return "\(index) \(image) \(hexString(address)) \(symbol) + \(offset)"
    }

    private static func hexString(_ address: UInt) -> String {
        let raw = String(address, radix: 16)
        let width = MemoryLayout<UInt>.size * 2
        let padding = String(repeating: "0", count: max(0, width - raw.count))
        return "0x\(padding)\(raw)"
    }
}
