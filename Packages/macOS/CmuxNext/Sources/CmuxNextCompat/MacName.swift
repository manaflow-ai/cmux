import Foundation
import SystemConfiguration

/// This Mac's names, read without DNS. `Host.current().localizedName` and
/// `ProcessInfo.hostName` resolve every local name through DNS/mDNS and
/// have blocked the main thread for ~35 s; check-concurrency bans both.
/// It lives in CmuxNextCompat (not CmuxNextApp) so the App target does not grow (SW14).
public struct MacName: Sendable {
    public init() {}

    /// The user-visible computer name (System Settings > General > Sharing),
    /// from the local configuration store, read off the main actor. Falls
    /// back to the kernel host name, then "Mac".
    public func computerName() async -> String {
        await Self.resolve {
            SCDynamicStoreCopyComputerName(nil, nil) as String?
        }
    }

    /// Runs `read` off the main actor (it may do IPC) and applies the fallbacks.
    @concurrent private static func resolve(_ read: @Sendable () -> String?) async -> String {
        if let name = read()?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        let host = MacName().kernelHostName()
        return host.isEmpty ? "Mac" : host
    }

    /// `cmux-<host>`, as the old app named its Cloud link device (moved from
    /// CloudService). Reads the kernel hostname: `ProcessInfo.hostName`
    /// resolves through DNS and blocked the main thread for 35 s on launch.
    public nonisolated func linkDeviceName() -> String {
        let name = kernelHostName()
        let host = name.isEmpty ? "mac" : name
        let cleaned = host.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return "cmux-" + String(String(cleaned).prefix(40))
    }

    /// The kernel host name's first label (`gethostname`: a syscall, no DNS).
    public nonisolated func kernelHostName() -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count) == 0 else { return "" }
        let raw = String(cString: buffer)
        return raw.split(separator: ".").first.map(String.init) ?? raw
    }
}
