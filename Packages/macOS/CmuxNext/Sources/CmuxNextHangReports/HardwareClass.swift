public import Foundation

/// The kind of Mac, coarse enough to be shared by many people: architecture, chip family, core
/// count and memory rounded to a size Apple sells. No model identifier, serial or host name.
public nonisolated struct HardwareClass: Codable, Sendable, Equatable {
    /// `arm64`, `x86_64` or `other`.
    public var arch: String
    /// `Apple M<n>[ Pro| Max| Ultra]`, `Intel` or `other`.
    public var chip: String
    /// Active processor cores.
    public var cores: Int
    /// Physical memory rounded to the nearest size Apple sells.
    public var memoryGB: Int

    /// Makes the value from its parts.
    public init(arch: String, chip: String, cores: Int, memoryGB: Int) {
        self.arch = arch
        self.chip = chip
        self.cores = cores
        self.memoryGB = memoryGB
    }

    /// The class from raw values (sysctl `hw.machine`, `machdep.cpu.brand_string`), each
    /// reduced to its allowed form by Rust (``HangReportRules``); `other`, `other`, 1 core and 0 GB
    /// when the rules do not answer.
    public init(rawArch: String?, rawChip: String?, cores: Int, memoryBytes: UInt64) {
        struct Request: Encodable {
            var rawArch: String?
            var rawChip: String?
            var cores: Int
            var memoryBytes: UInt64
        }
        let request = Request(rawArch: rawArch, rawChip: rawChip, cores: cores, memoryBytes: memoryBytes)
        self = HangReportRules.call("hardware", request, as: HardwareClass.self)
            ?? HardwareClass(arch: "other", chip: "other", cores: 1, memoryGB: 0)
    }

    /// This Mac's class (sysctl and `ProcessInfo`).
    public static func current() -> HardwareClass {
        HardwareClass(rawArch: sysctlString("hw.machine"), rawChip: sysctlString("machdep.cpu.brand_string"),
                      cores: ProcessInfo.processInfo.activeProcessorCount, memoryBytes: ProcessInfo.processInfo.physicalMemory)
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0, size < 256 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return nil }
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
