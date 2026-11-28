import Foundation
import SystemConfiguration

/// This Mac's names, read without DNS. `Host.current().localizedName` and
/// `ProcessInfo.hostName` resolve every local name through DNS/mDNS and
/// have blocked the main thread for ~35 s; check-concurrency bans both.
enum MacName {
    /// The user-visible computer name (System Settings > General > Sharing),
    /// from the local configuration store, read off the main actor. Falls
    /// back to the kernel host name, then "Mac".
    static func computerName() async -> String {
        await resolve {
            SCDynamicStoreCopyComputerName(nil, nil) as String?
        }
    }

    /// Runs `read` off the main actor (it may do IPC) and applies the fallbacks.
    @concurrent static func resolve(_ read: @Sendable () -> String?) async -> String {
        if let name = read()?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        let host = kernelHostName()
        return host.isEmpty ? "Mac" : host
    }

    /// The kernel host name's first label (`gethostname`: a syscall, no DNS).
    nonisolated static func kernelHostName() -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count) == 0 else { return "" }
        let raw = String(cString: buffer)
        return raw.split(separator: ".").first.map(String.init) ?? raw
    }
}
