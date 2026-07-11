import Darwin
import Foundation

/// Fail-closed host-process identity for Android Emulator windows.
public enum AndroidEmulatorProcessIdentity {
    /// Returns whether the process command line identifies the selected AVD.
    public static func matches(processIdentifier: Int32, avdName: String) -> Bool {
        guard processIdentifier > 0,
              let arguments = commandLineArguments(processIdentifier: processIdentifier) else {
            return false
        }
        return argumentsMatchAVD(arguments, avdName: avdName)
    }

    static func argumentsMatchAVD(_ arguments: [String], avdName: String) -> Bool {
        if arguments.contains("@\(avdName)") {
            return true
        }
        return arguments.indices.contains { index in
            arguments[index] == "-avd"
                && arguments.indices.contains(index + 1)
                && arguments[index + 1] == avdName
        }
    }

    static func parseKernProcArguments(_ bytes: [UInt8]) -> [String]? {
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
            guard let argument = String(bytes: bytes[start..<index], encoding: .utf8) else {
                return nil
            }
            arguments.append(argument)
            if index < bytes.count { index += 1 }
        }
        return arguments
    }

    private static func commandLineArguments(processIdentifier: Int32) -> [String]? {
        var mib = [CTL_KERN, KERN_PROCARGS2, processIdentifier]
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
        return parseKernProcArguments(Array(buffer.prefix(Int(size))))
    }

    private static func skipString(in bytes: [UInt8], index: inout Int) {
        while index < bytes.count, bytes[index] != 0 { index += 1 }
    }

    private static func skipNulls(in bytes: [UInt8], index: inout Int) {
        while index < bytes.count, bytes[index] == 0 { index += 1 }
    }
}
