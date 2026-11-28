public import Foundation

/// Activity Monitor-style text: CPU as a percentage of one core with one
/// decimal ("12.3%", above 100% on several cores), memory in binary units
/// ("145.2 MB"), both in the user's locale.
public struct ResourceFormat {
    public init() {}
    public static func cpu(_ share: Double, locale: Locale = .current) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .percent
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 1
        return formatter.string(from: NSNumber(value: max(share, 0))) ?? "\(max(share, 0) * 100)%"
    }

    /// Memory text; the dash for zero bytes. A live process always has a footprint, so zero is a read
    /// that measured nothing (a remote daemon that could not read it, a sample of no processes), never
    /// "Zero KB" (ask-3729c9c563, Leo 2026-11-27: "the memory line... it should be the ram usage").
    public static func memory(_ bytes: UInt64) -> String {
        guard bytes > 0 else { return Strings.pending }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.includesActualByteCount = false
        return formatter.string(fromByteCount: Int64(clamping: bytes))
    }

    /// "CPU 2.3% · Memory 145.2 MB"; the CPU value is a dash until the
    /// second sample, and both are dashes for a sample that measured nothing (not "0.0% · Zero KB").
    public static func line(_ usage: ResourceUsage) -> String {
        Strings.cpuMemory(cpu: cpuText(usage), memory: memory(usage.memoryBytes))
    }

    /// "2.3% · 145.2 MB" for list rows.
    public static func compact(_ usage: ResourceUsage) -> String {
        Strings.compact(cpu: cpuText(usage), memory: memory(usage.memoryBytes))
    }

    /// The CPU of `usage`; the dash before a second sample and when nothing was measured (no memory).
    static func cpuText(_ usage: ResourceUsage) -> String {
        guard usage.memoryBytes > 0, let share = usage.cpu else { return Strings.pending }
        return cpu(share)
    }

    /// "Shared (cmux, GPU, Network): CPU 1.0% · Memory 400 MB".
    public static func shared(_ usage: ResourceUsage, roles: [SharedRole]) -> String {
        Strings.shared(roles: roles.map(Strings.role).joined(separator: Strings.listSeparator), usage: line(usage))
    }
}

/// Localized strings of CmuxNextResources (Resources/Localizable.xcstrings).
enum Strings {
    static var pending: String { String(localized: "resources.pending", defaultValue: "–", bundle: .localizedModule) }
    static var unavailable: String {
        String(localized: "resources.unavailable", defaultValue: "Resource usage unavailable", bundle: .localizedModule)
    }
    static var listSeparator: String { String(localized: "resources.listSeparator", defaultValue: ", ", bundle: .localizedModule) }

    static func cpuMemory(cpu: String, memory: String) -> String {
        String(format: String(localized: "resources.line", defaultValue: "CPU %1$@ · Memory %2$@", bundle: .localizedModule), cpu, memory)
    }

    static func compact(cpu: String, memory: String) -> String {
        String(format: String(localized: "resources.compact", defaultValue: "%1$@ · %2$@", bundle: .localizedModule), cpu, memory)
    }

    static func shared(roles: String, usage: String) -> String {
        String(format: String(localized: "resources.shared", defaultValue: "Shared (%1$@): %2$@", bundle: .localizedModule), roles, usage)
    }

    static func role(_ role: SharedRole) -> String {
        switch role {
        case .app: String(localized: "resources.role.app", defaultValue: "cmux", bundle: .localizedModule)
        case .gpu: String(localized: "resources.role.gpu", defaultValue: "GPU", bundle: .localizedModule)
        case .network: String(localized: "resources.role.network", defaultValue: "Network", bundle: .localizedModule)
        case .utility: String(localized: "resources.role.utility", defaultValue: "Utilities", bundle: .localizedModule)
        case .extensions: String(localized: "resources.role.extensions", defaultValue: "Extensions", bundle: .localizedModule)
        }
    }

    static var untitled: String { String(localized: "resources.untitled", defaultValue: "Untitled", bundle: .localizedModule) }
}
