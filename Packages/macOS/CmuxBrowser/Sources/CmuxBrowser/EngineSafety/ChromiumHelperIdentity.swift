import Darwin
import Foundation

/// A Chromium helper's `--type` and related switches, read from its argv.
public struct ChromiumHelperIdentity: Equatable, Sendable {
    public var processType: String
    public var subType: String?
    public var isExtension: Bool

    public init(processType: String, subType: String? = nil, isExtension: Bool = false) {
        self.processType = processType
        self.subType = subType
        self.isExtension = isExtension
    }

    /// The name a crash record uses: `extension` for an extension renderer,
    /// otherwise the `--type` value.
    public var recordedType: String { isExtension ? "extension" : processType }

    public static func read(pid: Int32) -> ChromiumHelperIdentity? {
        parse(arguments(pid: pid))
    }

    /// Nil for a process that is not a Chromium helper (no `--type=`).
    public static func parse(_ arguments: [String]) -> ChromiumHelperIdentity? {
        var type: String?
        var subType: String?
        var isExtension = false
        for argument in arguments {
            if argument.hasPrefix("--type=") {
                type = String(argument.dropFirst("--type=".count))
            } else if argument.hasPrefix("--utility-sub-type=") {
                subType = String(argument.dropFirst("--utility-sub-type=".count))
            } else if argument == "--extension-process" {
                isExtension = true
            }
        }
        guard let type, !type.isEmpty else { return nil }
        return ChromiumHelperIdentity(processType: type, subType: subType, isExtension: isExtension)
    }

    /// argv of `pid` from KERN_PROCARGS2: argc, exec path, padding, argv.
    public static func arguments(pid: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        return parseProcArgs(Array(buffer.prefix(size)))
    }

    static func parseProcArgs(_ buffer: [UInt8]) -> [String] {
        let intSize = MemoryLayout<Int32>.size
        guard buffer.count > intSize else { return [] }
        let argc = buffer.prefix(intSize).withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        guard argc > 0 else { return [] }
        var index = intSize
        // Skip the exec path and the NUL padding after it.
        while index < buffer.count, buffer[index] != 0 { index += 1 }
        while index < buffer.count, buffer[index] == 0 { index += 1 }
        var result: [String] = []
        while index < buffer.count, result.count < argc {
            let start = index
            while index < buffer.count, buffer[index] != 0 { index += 1 }
            result.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return result
    }
}
