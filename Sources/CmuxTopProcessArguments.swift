import Darwin
import Foundation

struct CmuxTopProcessArguments: Sendable {
    let arguments: [String]
    let environment: [String: String]
}

extension CmuxTopProcessSnapshot {
    static func processArgumentsAndEnvironment(for pid: Int) -> CmuxTopProcessArguments? {
        guard pid > 0, pid <= Int(Int32.max),
              let bytes = kernProcArgsBytes(for: pid) else {
            return nil
        }
        return processArgumentsAndEnvironment(fromKernProcArgs: bytes)
    }

    static func processArgumentsAndEnvironment(fromKernProcArgs bytes: [UInt8]) -> CmuxTopProcessArguments? {
        guard bytes.count > MemoryLayout<Int32>.size else { return nil }

        var argcRaw: Int32 = 0
        withUnsafeMutableBytes(of: &argcRaw) { rawBuffer in
            rawBuffer.copyBytes(from: bytes.prefix(MemoryLayout<Int32>.size))
        }
        let argc = Int(Int32(littleEndian: argcRaw))
        guard argc > 0 else { return nil }

        var index = MemoryLayout<Int32>.size
        skipString(in: bytes, index: &index)
        skipNulls(in: bytes, index: &index)

        var arguments: [String] = []
        for _ in 0..<argc {
            guard index < bytes.count else { return nil }
            let start = index
            skipString(in: bytes, index: &index)
            if let argument = String(bytes: bytes[start..<index], encoding: .utf8) {
                arguments.append(argument)
            }
            consumeTerminatingNull(in: bytes, index: &index)
        }

        var environment: [String: String] = [:]
        while index < bytes.count {
            skipNulls(in: bytes, index: &index)
            guard index < bytes.count else { break }
            let start = index
            skipString(in: bytes, index: &index)
            guard start < index,
                  let entry = String(bytes: bytes[start..<index], encoding: .utf8),
                  let equals = entry.firstIndex(of: "=") else {
                continue
            }
            let key = String(entry[..<equals])
            guard !key.isEmpty else { continue }
            environment[key] = String(entry[entry.index(after: equals)...])
        }

        return CmuxTopProcessArguments(arguments: arguments, environment: environment)
    }

    private static func kernProcArgsBytes(for pid: Int) -> [UInt8]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, Int32(pid)]
        var size: size_t = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size else {
            return nil
        }

        var buffer = [UInt8](repeating: 0, count: size)
        let success = buffer.withUnsafeMutableBytes { rawBuffer in
            sysctl(&mib, u_int(mib.count), rawBuffer.baseAddress, &size, nil, 0) == 0
        }
        guard success else { return nil }
        return Array(buffer.prefix(Int(size)))
    }

    private static func skipString(in bytes: [UInt8], index: inout Int) {
        while index < bytes.count, bytes[index] != 0 {
            index += 1
        }
    }

    private static func skipNulls(in bytes: [UInt8], index: inout Int) {
        while index < bytes.count, bytes[index] == 0 {
            index += 1
        }
    }

    private static func consumeTerminatingNull(in bytes: [UInt8], index: inout Int) {
        if index < bytes.count, bytes[index] == 0 {
            index += 1
        }
    }
}
