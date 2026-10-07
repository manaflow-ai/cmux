import Foundation

/// Where a run happened. Load matters: the shared dev Mac runs many agents.
public struct MachineInfo: Codable, Sendable {
    public var model: String
    public var cpu: String
    public var cores: Int
    public var os: String
    public var loadAverage1m: Double

    static func current() -> MachineInfo {
        func sysctl(_ name: String) -> String {
            var size = 0
            guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "" }
            var buffer = [CChar](repeating: 0, count: size)
            guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "" }
            return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        var load = [Double](repeating: 0, count: 3)
        getloadavg(&load, 3)
        return MachineInfo(
            model: sysctl("hw.model"),
            cpu: sysctl("machdep.cpu.brand_string"),
            cores: ProcessInfo.processInfo.activeProcessorCount,
            os: ProcessInfo.processInfo.operatingSystemVersionString,
            loadAverage1m: (load[0] * 100).rounded() / 100
        )
    }
}
