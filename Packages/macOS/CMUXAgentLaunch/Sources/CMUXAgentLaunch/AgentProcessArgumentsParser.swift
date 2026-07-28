import Darwin
import Foundation

/// Parses macOS `KERN_PROCARGS2` buffers for agent discovery.
///
/// Use ``filterMetadata(fromKernProcArgs:normalizedArgumentNeedles:)`` on hot
/// paths and defer ``argumentsAndEnvironment(fromKernProcArgs:)`` until the
/// metadata identifies a process worth fully decoding.
public struct AgentProcessArgumentsParser: Sendable {
    /// Creates a stateless process-argument parser.
    public init() {}

    /// Reads and decodes the current arguments and environment for a process.
    ///
    /// - Parameter pid: A positive Darwin process identifier.
    /// - Returns: The decoded arguments, or `nil` when the process disappeared
    ///   or its kernel buffer is malformed.
    public func argumentsAndEnvironment(for pid: Int) -> AgentProcessArguments? {
        guard pid > 0, pid <= Int(Int32.max),
              let bytes = kernProcArgsBytes(for: pid) else {
            return nil
        }
        return argumentsAndEnvironment(fromKernProcArgs: bytes)
    }

    /// Decodes a captured `KERN_PROCARGS2` buffer.
    ///
    /// - Parameter bytes: The complete bytes returned by `KERN_PROCARGS2`.
    /// - Returns: The decoded arguments and environment, or `nil` for a
    ///   malformed buffer.
    public func argumentsAndEnvironment(
        fromKernProcArgs bytes: [UInt8]
    ) -> AgentProcessArguments? {
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

        return AgentProcessArguments(
            arguments: arguments,
            environment: environment
        )
    }

    /// Extracts the project working directory without decoding full argv.
    ///
    /// - Parameter bytes: The complete bytes returned by `KERN_PROCARGS2`.
    /// - Returns: `CMUX_AGENT_LAUNCH_CWD` when present, otherwise `PWD`.
    public func projectWorkingDirectory(
        fromKernProcArgs bytes: [UInt8]
    ) -> String? {
        filterMetadata(
            fromKernProcArgs: bytes,
            normalizedArgumentNeedles: []
        )?.projectWorkingDirectory
    }

    /// Extracts the fields needed by the agent-process candidate filter.
    ///
    /// - Parameters:
    ///   - bytes: The complete bytes returned by `KERN_PROCARGS2`.
    ///   - normalizedArgumentNeedles: Lowercase UTF-8 needles whose backslashes
    ///     have already been normalized to forward slashes.
    /// - Returns: Lightweight metadata, or `nil` for a malformed buffer.
    public func filterMetadata(
        fromKernProcArgs bytes: [UInt8],
        normalizedArgumentNeedles: [[UInt8]]
    ) -> AgentProcessFilterMetadata? {
        var argumentsContainAnyNeedle = false
        var launchWorkingDirectory: String?
        var sawLaunchWorkingDirectory = false
        var pwd: String?
        var agentLaunchKind: String?
        var agentLaunchExecutable: String?
        var argumentIndex = 0
        var firstArgumentAfterExecutableRange: Range<Int>?
        let traversal = visitProcessArgumentsAndEnvironment(
            fromKernProcArgs: bytes,
            visitArgument: { baseAddress, length, byteOffset in
                defer { argumentIndex += 1 }
                if argumentIndex == 1 {
                    firstArgumentAfterExecutableRange = byteOffset..<(byteOffset + length)
                }
                if !argumentsContainAnyNeedle {
                    argumentsContainAnyNeedle = normalizedArgumentNeedles.contains {
                        argumentContains(
                            baseAddress: baseAddress,
                            length: length,
                            needle: $0
                        )
                    }
                }
                return false
            },
            visitEnvironment: { baseAddress, length in
                if baseAddress[0] == Self.launchWorkingDirectoryEnvironmentPrefix[0],
                   let value = environmentValue(
                       baseAddress: baseAddress,
                       length: length,
                       prefix: Self.launchWorkingDirectoryEnvironmentPrefix
                   ) {
                    sawLaunchWorkingDirectory = true
                    launchWorkingDirectory = value
                } else if baseAddress[0] == Self.pwdEnvironmentPrefix[0],
                          let value = environmentValue(
                              baseAddress: baseAddress,
                              length: length,
                              prefix: Self.pwdEnvironmentPrefix
                          ) {
                    pwd = value
                } else if baseAddress[0] == Self.launchKindEnvironmentPrefix[0],
                          let value = environmentValue(
                              baseAddress: baseAddress,
                              length: length,
                              prefix: Self.launchKindEnvironmentPrefix
                          ) {
                    agentLaunchKind = value
                } else if baseAddress[0] == Self.launchExecutableEnvironmentPrefix[0],
                          let value = environmentValue(
                              baseAddress: baseAddress,
                              length: length,
                              prefix: Self.launchExecutableEnvironmentPrefix
                          ) {
                    agentLaunchExecutable = value
                }
                return false
            }
        )
        guard traversal != nil else { return nil }

        let firstArgumentAfterExecutable: String?
        if agentLaunchKind != nil,
           agentLaunchExecutable != nil,
           let range = firstArgumentAfterExecutableRange {
            firstArgumentAfterExecutable = String(bytes: bytes[range], encoding: .utf8)
        } else {
            firstArgumentAfterExecutable = nil
        }

        return AgentProcessFilterMetadata(
            projectWorkingDirectory: sawLaunchWorkingDirectory ? launchWorkingDirectory : pwd,
            argumentsContainAnyNeedle: argumentsContainAnyNeedle,
            agentLaunchKind: agentLaunchKind,
            agentLaunchExecutable: agentLaunchExecutable,
            firstArgumentAfterExecutable: firstArgumentAfterExecutable
        )
    }

    /// Reads the raw `KERN_PROCARGS2` bytes for a live process.
    ///
    /// - Parameter pid: A positive Darwin process identifier.
    /// - Returns: The exact kernel buffer, or `nil` when it cannot be read.
    public func kernProcArgsBytes(for pid: Int) -> [UInt8]? {
        guard pid > 0, pid <= Int(Int32.max) else { return nil }
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

    private func environmentValue(
        baseAddress: UnsafePointer<UInt8>,
        length: Int,
        prefix: [UInt8]
    ) -> String? {
        guard length >= prefix.count else {
            return nil
        }
        let matches = prefix.withUnsafeBufferPointer { prefixBuffer in
            guard let prefixAddress = prefixBuffer.baseAddress else { return false }
            return memcmp(
                baseAddress,
                prefixAddress,
                prefixBuffer.count
            ) == 0
        }
        guard matches else { return nil }
        return String(
            bytes: UnsafeBufferPointer(
                start: baseAddress.advanced(by: prefix.count),
                count: length - prefix.count
            ),
            encoding: .utf8
        )
    }

    private static let launchWorkingDirectoryEnvironmentPrefix = Array(
        "CMUX_AGENT_LAUNCH_CWD=".utf8
    )
    private static let launchKindEnvironmentPrefix = Array(
        "CMUX_AGENT_LAUNCH_KIND=".utf8
    )
    private static let launchExecutableEnvironmentPrefix = Array(
        "CMUX_AGENT_LAUNCH_EXECUTABLE=".utf8
    )
    private static let pwdEnvironmentPrefix = Array("PWD=".utf8)

    /// Visits argv and environment entries without constructing full collections.
    private func visitProcessArgumentsAndEnvironment(
        fromKernProcArgs bytes: [UInt8],
        visitArgument: (UnsafePointer<UInt8>, Int, Int) -> Bool = { _, _, _ in false },
        visitEnvironment: (UnsafePointer<UInt8>, Int) -> Bool = { _, _ in false }
    ) -> Bool? {
        guard bytes.count > MemoryLayout<Int32>.size else { return nil }
        return bytes.withUnsafeBufferPointer { buffer -> Bool? in
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
                let start = index
                guard skipCString(
                    baseAddress: baseAddress,
                    count: buffer.count,
                    index: &index
                ) else {
                    return nil
                }
                if visitArgument(baseAddress.advanced(by: start), index - start, start) {
                    return true
                }
                index += 1
            }

            while index < buffer.count {
                skipNullBytes(baseAddress: baseAddress, count: buffer.count, index: &index)
                guard index < buffer.count else { break }
                let start = index
                guard skipCString(
                    baseAddress: baseAddress,
                    count: buffer.count,
                    index: &index
                ) else {
                    return nil
                }
                if visitEnvironment(baseAddress.advanced(by: start), index - start) {
                    return true
                }
                index += 1
            }
            return false
        }
    }

    private func argumentContains(
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

    private func normalizedArgumentByte(_ byte: UInt8) -> UInt8 {
        if byte == 0x5C { return 0x2F }
        if byte >= 0x41, byte <= 0x5A { return byte + 0x20 }
        return byte
    }

    private func skipCString(
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

    private func skipNullBytes(
        baseAddress: UnsafePointer<UInt8>,
        count: Int,
        index: inout Int
    ) {
        while index < count, baseAddress[index] == 0 {
            index += 1
        }
    }

    private func skipString(in bytes: [UInt8], index: inout Int) {
        while index < bytes.count, bytes[index] != 0 {
            index += 1
        }
    }

    private func skipNulls(in bytes: [UInt8], index: inout Int) {
        while index < bytes.count, bytes[index] == 0 {
            index += 1
        }
    }

    private func consumeTerminatingNull(in bytes: [UInt8], index: inout Int) {
        if index < bytes.count, bytes[index] == 0 {
            index += 1
        }
    }
}
