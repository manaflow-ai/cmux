import Darwin
import Foundation

/// Reads foreground-process identity and launch metadata outside the app target.
public struct AgentTerminalProcessInspector: Sendable {
    /// Creates a stateless process inspector.
    public init() {}

    /// Captures one process generation with its executable, arguments, and environment.
    @concurrent
    public func snapshot(pid: Int32, runtimeGeneration: UInt64) async -> AgentTerminalProcessSnapshot? {
        guard let identity = processIdentity(pid: pid, runtimeGeneration: runtimeGeneration) else { return nil }
        let command = processArgumentsAndEnvironment(pid: pid)
        return AgentTerminalProcessSnapshot(
            identity: identity,
            executablePath: executablePath(pid: pid),
            arguments: command?.arguments ?? [],
            environment: command?.environment ?? [:]
        )
    }

    /// Re-reads only the stable process identity for post-capture validation.
    @concurrent
    public func identity(pid: Int32, runtimeGeneration: UInt64) async -> AgentTerminalProcessIdentity? {
        processIdentity(pid: pid, runtimeGeneration: runtimeGeneration)
    }

    private func processIdentity(pid: Int32, runtimeGeneration: UInt64) -> AgentTerminalProcessIdentity? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let expectedSize = MemoryLayout<proc_bsdinfo>.stride
        let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(expectedSize))
        guard size == expectedSize else { return nil }
        return AgentTerminalProcessIdentity(
            pid: pid,
            startSeconds: Int64(info.pbi_start_tvsec),
            startMicroseconds: Int64(info.pbi_start_tvusec),
            runtimeGeneration: runtimeGeneration
        )
    }

    private func executablePath(pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let count = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard count > 0 else { return nil }
        let pathBytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: pathBytes, as: UTF8.self)
    }

    private func processArgumentsAndEnvironment(pid: Int32) -> (arguments: [String], environment: [String: String])? {
        guard let bytes = kernProcArgsBytes(pid: pid), bytes.count > MemoryLayout<Int32>.size else { return nil }
        var argcRaw: Int32 = 0
        withUnsafeMutableBytes(of: &argcRaw) { destination in
            destination.copyBytes(from: bytes.prefix(MemoryLayout<Int32>.size))
        }
        let argumentCount = Int(Int32(littleEndian: argcRaw))
        guard argumentCount > 0 else { return nil }

        var index = MemoryLayout<Int32>.size
        skipString(in: bytes, index: &index)
        skipNulls(in: bytes, index: &index)
        var arguments: [String] = []
        for _ in 0..<argumentCount {
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
                  let equals = entry.firstIndex(of: "=") else { continue }
            let key = String(entry[..<equals])
            guard !key.isEmpty else { continue }
            environment[key] = String(entry[entry.index(after: equals)...])
        }
        return (arguments, environment)
    }

    private func kernProcArgsBytes(pid: Int32) -> [UInt8]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size: size_t = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        let success = buffer.withUnsafeMutableBytes { rawBuffer in
            sysctl(&mib, u_int(mib.count), rawBuffer.baseAddress, &size, nil, 0) == 0
        }
        guard success else { return nil }
        return Array(buffer.prefix(Int(size)))
    }

    private func skipString(in bytes: [UInt8], index: inout Int) {
        while index < bytes.count, bytes[index] != 0 { index += 1 }
    }

    private func skipNulls(in bytes: [UInt8], index: inout Int) {
        while index < bytes.count, bytes[index] == 0 { index += 1 }
    }

    private func consumeTerminatingNull(in bytes: [UInt8], index: inout Int) {
        if index < bytes.count, bytes[index] == 0 { index += 1 }
    }
}
