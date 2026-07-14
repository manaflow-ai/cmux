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

    /// Reads only the environment keys that choose a project-local cmux config.
    /// The full argv/environment buffer is intentionally left undecoded so callers can
    /// discard noncandidate process buffers without allocating every argument and value.
    static func processProjectWorkingDirectory(fromKernProcArgs bytes: [UInt8]) -> String? {
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
        for _ in 0..<argc {
            guard index < bytes.count else { return nil }
            skipString(in: bytes, index: &index)
            consumeTerminatingNull(in: bytes, index: &index)
        }

        var launchWorkingDirectory: String?
        var sawLaunchWorkingDirectory = false
        var pwd: String?
        while index < bytes.count {
            skipNulls(in: bytes, index: &index)
            guard index < bytes.count else { break }
            let start = index
            skipString(in: bytes, index: &index)
            guard start < index else { continue }

            if let value = environmentValue(
                in: bytes[start..<index],
                prefix: launchWorkingDirectoryEnvironmentPrefix
            ) {
                sawLaunchWorkingDirectory = true
                launchWorkingDirectory = value
            } else if let value = environmentValue(
                in: bytes[start..<index],
                prefix: pwdEnvironmentPrefix
            ) {
                pwd = value
            }
        }

        return sawLaunchWorkingDirectory ? launchWorkingDirectory : pwd
    }

    /// Checks argument entries for pre-normalized ASCII needles without
    /// allocating the complete argv/environment object graph.
    static func processArgumentsContainAnyNeedle(
        fromKernProcArgs bytes: [UInt8],
        normalizedNeedles: [[UInt8]]
    ) -> Bool {
        guard !normalizedNeedles.isEmpty,
              bytes.count > MemoryLayout<Int32>.size else { return false }

        var argcRaw: Int32 = 0
        withUnsafeMutableBytes(of: &argcRaw) { rawBuffer in
            rawBuffer.copyBytes(from: bytes.prefix(MemoryLayout<Int32>.size))
        }
        let argc = Int(Int32(littleEndian: argcRaw))
        guard argc > 0 else { return false }

        var index = MemoryLayout<Int32>.size
        skipString(in: bytes, index: &index)
        skipNulls(in: bytes, index: &index)
        for _ in 0..<argc {
            guard index < bytes.count else { return false }
            let start = index
            skipString(in: bytes, index: &index)
            let argument = bytes[start..<index]
            if normalizedNeedles.contains(where: { argumentContains(argument, needle: $0) }) {
                return true
            }
            consumeTerminatingNull(in: bytes, index: &index)
        }
        return false
    }

    static func kernProcArgsBytes(for pid: Int) -> [UInt8]? {
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
        guard success, size <= buffer.count else { return nil }
        buffer.removeLast(buffer.count - Int(size))
        return buffer
    }

    private static func environmentValue(
        in entry: ArraySlice<UInt8>,
        prefix: [UInt8]
    ) -> String? {
        guard entry.count >= prefix.count,
              entry.prefix(prefix.count).elementsEqual(prefix) else {
            return nil
        }
        return String(bytes: entry.dropFirst(prefix.count), encoding: .utf8)
    }

    private static let launchWorkingDirectoryEnvironmentPrefix = Array(
        "CMUX_AGENT_LAUNCH_CWD=".utf8
    )
    private static let pwdEnvironmentPrefix = Array("PWD=".utf8)

    private static func argumentContains(
        _ argument: ArraySlice<UInt8>,
        needle: [UInt8]
    ) -> Bool {
        guard !needle.isEmpty, argument.count >= needle.count else { return false }
        let lastStart = argument.count - needle.count
        for offset in 0...lastStart {
            let start = argument.index(argument.startIndex, offsetBy: offset)
            var matches = true
            for needleOffset in needle.indices {
                let argumentIndex = argument.index(start, offsetBy: needleOffset)
                if normalizedArgumentByte(argument[argumentIndex]) != needle[needleOffset] {
                    matches = false
                    break
                }
            }
            if matches { return true }
        }
        return false
    }

    private static func normalizedArgumentByte(_ byte: UInt8) -> UInt8 {
        if byte == 0x5C { return 0x2F } // Backslash to slash.
        if byte >= 0x41, byte <= 0x5A { return byte + 0x20 }
        return byte
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
