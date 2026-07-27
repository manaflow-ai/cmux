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

    static func processProjectWorkingDirectory(fromKernProcArgs bytes: [UInt8]) -> String? {
        guard bytes.count > MemoryLayout<Int32>.size else { return nil }
        return bytes.withUnsafeBufferPointer { buffer -> String? in
            guard let baseAddress = buffer.baseAddress else { return nil }
            var argcRaw: Int32 = 0
            _ = withUnsafeMutablePointer(to: &argcRaw) {
                memcpy($0, baseAddress, MemoryLayout<Int32>.size)
            }
            let argc = Int(Int32(littleEndian: argcRaw))
            guard argc > 0 else { return nil }

            var index = MemoryLayout<Int32>.size
            guard skipCString(
                baseAddress: baseAddress,
                count: buffer.count,
                index: &index
            ) else {
                return nil
            }
            skipNullBytes(baseAddress: baseAddress, count: buffer.count, index: &index)
            for _ in 0..<argc {
                guard skipCString(
                    baseAddress: baseAddress,
                    count: buffer.count,
                    index: &index
                ) else {
                    return nil
                }
                index += 1
            }

            var launchWorkingDirectory: String?
            var sawLaunchWorkingDirectory = false
            var pwd: String?
            while index < buffer.count {
                skipNullBytes(baseAddress: baseAddress, count: buffer.count, index: &index)
                guard index < buffer.count else { break }
                let start = index
                guard skipCString(
                    baseAddress: baseAddress,
                    count: buffer.count,
                    index: &index
                ) else {
                    break
                }
                let end = index
                if baseAddress[start] == launchWorkingDirectoryEnvironmentPrefix[0],
                   let value = environmentValue(
                       baseAddress: baseAddress,
                       start: start,
                       end: end,
                       prefix: launchWorkingDirectoryEnvironmentPrefix
                   ) {
                    sawLaunchWorkingDirectory = true
                    launchWorkingDirectory = value
                } else if baseAddress[start] == pwdEnvironmentPrefix[0],
                          let value = environmentValue(
                              baseAddress: baseAddress,
                              start: start,
                              end: end,
                              prefix: pwdEnvironmentPrefix
                          ) {
                    pwd = value
                }
                index += 1
            }

            return sawLaunchWorkingDirectory ? launchWorkingDirectory : pwd
        }
    }

    static func processArgumentsContainAnyNeedle(
        fromKernProcArgs bytes: [UInt8],
        normalizedNeedles: [[UInt8]]
    ) -> Bool {
        guard !normalizedNeedles.isEmpty,
              bytes.count > MemoryLayout<Int32>.size else {
            return false
        }

        return bytes.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return false }
            var argcRaw: Int32 = 0
            _ = withUnsafeMutablePointer(to: &argcRaw) {
                memcpy($0, baseAddress, MemoryLayout<Int32>.size)
            }
            let argc = Int(Int32(littleEndian: argcRaw))
            guard argc > 0 else { return false }

            var index = MemoryLayout<Int32>.size
            guard skipCString(
                baseAddress: baseAddress,
                count: buffer.count,
                index: &index
            ) else {
                return false
            }
            skipNullBytes(baseAddress: baseAddress, count: buffer.count, index: &index)
            for _ in 0..<argc {
                let start = index
                guard skipCString(
                    baseAddress: baseAddress,
                    count: buffer.count,
                    index: &index
                ) else {
                    return false
                }
                let argumentLength = index - start
                if normalizedNeedles.contains(where: {
                    argumentContains(
                        baseAddress: baseAddress.advanced(by: start),
                        length: argumentLength,
                        needle: $0
                    )
                }) {
                    return true
                }
                index += 1
            }
            return false
        }
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
        baseAddress: UnsafePointer<UInt8>,
        start: Int,
        end: Int,
        prefix: [UInt8]
    ) -> String? {
        let entryLength = end - start
        guard entryLength >= prefix.count else {
            return nil
        }
        let matches = prefix.withUnsafeBufferPointer { prefixBuffer in
            guard let prefixAddress = prefixBuffer.baseAddress else { return false }
            return memcmp(
                baseAddress.advanced(by: start),
                prefixAddress,
                prefixBuffer.count
            ) == 0
        }
        guard matches else { return nil }
        return String(
            bytes: UnsafeBufferPointer(
                start: baseAddress.advanced(by: start + prefix.count),
                count: entryLength - prefix.count
            ),
            encoding: .utf8
        )
    }

    private static let launchWorkingDirectoryEnvironmentPrefix = Array(
        "CMUX_AGENT_LAUNCH_CWD=".utf8
    )
    private static let pwdEnvironmentPrefix = Array("PWD=".utf8)

    private static func argumentContains(
        baseAddress: UnsafePointer<UInt8>,
        length: Int,
        needle: [UInt8]
    ) -> Bool {
        guard !needle.isEmpty, length >= needle.count else { return false }
        let lastStart = length - needle.count
        for offset in 0...lastStart {
            var matches = true
            for needleOffset in needle.indices {
                if normalizedArgumentByte(baseAddress[offset + needleOffset]) != needle[needleOffset] {
                    matches = false
                    break
                }
            }
            if matches { return true }
        }
        return false
    }

    private static func normalizedArgumentByte(_ byte: UInt8) -> UInt8 {
        if byte == 0x5C { return 0x2F }
        if byte >= 0x41, byte <= 0x5A { return byte + 0x20 }
        return byte
    }

    private static func skipCString(
        baseAddress: UnsafePointer<UInt8>,
        count: Int,
        index: inout Int
    ) -> Bool {
        guard index < count,
              let terminator = memchr(baseAddress.advanced(by: index), 0, count - index) else {
            index = count
            return false
        }
        index = baseAddress.distance(to: terminator.assumingMemoryBound(to: UInt8.self))
        return true
    }

    private static func skipNullBytes(
        baseAddress: UnsafePointer<UInt8>,
        count: Int,
        index: inout Int
    ) {
        while index < count, baseAddress[index] == 0 {
            index += 1
        }
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
