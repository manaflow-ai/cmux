import Darwin
import Foundation

/// The CPU architecture an update should target on this Mac.
///
/// Nightly builds ship one DMG per architecture, so the updater has to pick the feed and
/// direct-download URL that match the machine. An x86_64 build running under Rosetta must
/// still resolve to `arm64`: the machine is Apple silicon, and the next update should be the
/// native build.
public enum UpdateHostArchitecture: String, Sendable, CaseIterable {
    case arm64
    case x86_64

    /// The architecture of the machine this process runs on, seen through Rosetta.
    public static var current: UpdateHostArchitecture {
        #if arch(arm64)
        return .arm64
        #else
        return isRosettaTranslated() ? .arm64 : .x86_64
        #endif
    }

    /// Whether the current process is an x86_64 binary being translated by Rosetta.
    static func isRosettaTranslated() -> Bool {
        var translated: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let status = sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0)
        return status == 0 && translated == 1
    }
}
