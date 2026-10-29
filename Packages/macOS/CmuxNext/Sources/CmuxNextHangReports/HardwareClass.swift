public import Foundation
import CmuxNextCompat

/// The kind of Mac, coarse enough to be shared by many people: architecture, chip family, core
/// count and memory rounded to a size Apple sells. No model identifier, serial or host name.
public nonisolated struct HardwareClass: Codable, Sendable, Equatable {
    /// `arm64`, `x86_64` or `other`.
    public var arch: String
    /// `Apple M<n>[ Pro| Max| Ultra]`, `Intel` or `other`.
    public var chip: String
    /// Active processor cores.
    public var cores: Int
    /// Physical memory rounded to the nearest of ``memorySizesGB``.
    public var memoryGB: Int

    /// The memory sizes a report may name.
    public static let memorySizesGB = [4, 8, 16, 18, 24, 32, 36, 48, 64, 96, 128, 192, 256, 512]

    /// Makes the value from its parts.
    public init(arch: String, chip: String, cores: Int, memoryGB: Int) {
        self.arch = arch
        self.chip = chip
        self.cores = cores
        self.memoryGB = memoryGB
    }

    /// The class from raw values (sysctl `hw.machine`, `machdep.cpu.brand_string`), each
    /// reduced to its allowed form.
    public init(rawArch: String?, rawChip: String?, cores: Int, memoryBytes: UInt64) {
        let arch = rawArch?.trimmingCharacters(in: .whitespaces) ?? ""
        self.arch = ["arm64", "arm64e", "x86_64"].contains(arch) ? (arch == "arm64e" ? "arm64" : arch) : "other"
        self.chip = Self.chipFamily(rawChip)
        self.cores = min(max(cores, 1), 1_024)
        let gigabytes = Double(memoryBytes) / 1_073_741_824
        self.memoryGB = Self.memorySizesGB.min { abs(Double($0) - gigabytes) < abs(Double($1) - gigabytes) } ?? 0
    }

    /// This Mac's class (sysctl and `ProcessInfo`).
    public static func current() -> HardwareClass {
        HardwareClass(rawArch: sysctlString("hw.machine"), rawChip: sysctlString("machdep.cpu.brand_string"),
                      cores: ProcessInfo.processInfo.activeProcessorCount, memoryBytes: ProcessInfo.processInfo.physicalMemory)
    }

    /// `Apple M4 Pro` stays; any other brand string becomes `Intel` or `other`.
    static func chipFamily(_ raw: String?) -> String {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return "other" }
        if raw.range(of: #"^Apple M[0-9]{1,2}( (Pro|Max|Ultra))?$"#, options: .regularExpression) != nil { return raw }
        return raw.localizedCaseInsensitiveContains("intel") ? "Intel" : "other"
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        // SAFETY: a nil buffer only asks for the length; sysctlbyname writes it into `size`, a local live for the call.
        guard unsafe blockingSysctlByName(name, nil, &size, nil, 0) == 0, size > 0, size < 256 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        // SAFETY: sysctlbyname writes at most `size` bytes into `bytes`, a local array of `size` elements live for
        // the call, and the length written into `size`; `name` is passed as a NUL-terminated temporary copy.
        guard unsafe blockingSysctlByName(name, &bytes, &size, nil, 0) == 0 else { return nil }
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
