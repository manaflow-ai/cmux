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
    /// back to the host name, then "Mac".
    public func computerName() async -> String {
        await Self.resolve {
            SCDynamicStoreCopyComputerName(nil, nil) as String?
        }
    }

    /// The name cmux shows for this Mac: the computer name, unless it is
    /// macOS's default ("Leo's MacBook Pro (3)") and the host name is not,
    /// then the host name ("cosmic-gray"), so machines that kept the default
    /// name are told apart by the name their owner gave them.
    public func displayName() async -> String {
        // Capture-only equivalent builds use a public fixture label so the fleet host name
        // never enters PR media; production builds retain the real machine name.
        if ProcessInfo.processInfo.environment["CMUX_CAPTURE_SANITIZE_NAMES"] == "1" { return "Fleet" }
        let computer = await computerName()
        return Self.displayName(computer: computer, localHost: await Self.localHostName(), kernel: kernelHostName())
    }

    /// `displayName()`'s pick from the names already read.
    nonisolated static func displayName(computer: String, localHost: String?, kernel: String) -> String {
        let host = hostName(localHost: localHost, kernel: kernel)
        return isDefaultName(computer) && !host.isEmpty && !isDefaultName(host) ? host : computer
    }

    /// The host name to show from the names already read: the local host
    /// name, else the kernel's.
    nonisolated static func hostName(localHost: String?, kernel: String) -> String {
        let local = localHost?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return local.isEmpty ? kernel : local
    }

    /// Whether `name` looks like a name macOS made up: one that names the
    /// hardware ("Leo's MacBook Pro (3)", "Leos-Mac-mini-2", "iMac").
    nonisolated static func isDefaultName(_ name: String) -> Bool {
        let model = #"\b(?:MacBook|Mac[ -]?mini|Mac[ -]?Studio|Mac[ -]?Pro|iMac)\b"#
        let owned = #"['’]s Mac(?: \(\d+\))?$"#
        return [model, owned].contains { name.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }

    /// Runs `read` off the main actor (it may do IPC) and applies the fallbacks.
    @concurrent private static func resolve(_ read: @Sendable () -> String?) async -> String {
        if let name = read()?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        let host = hostName(localHost: readLocalHostName(), kernel: MacName().kernelHostName())
        return host.isEmpty ? "Mac" : host
    }

    /// This Mac's stable host name: the local (Bonjour) host name its owner
    /// set in Sharing ("cosmic-gray"), else the kernel host name, which DHCP
    /// or reverse DNS can rename ("dhcp-10-0-1-5"). Synchronous callers (the
    /// main actor among them) never wait on configd: this returns the local
    /// host name a read off the main actor cached, and the kernel's until that
    /// read is done. The first call starts the read; `displayName()` renews it.
    public nonisolated func hostName() -> String {
        let (cached, start) = Self.localHost.withLock { state -> (String?, Bool) in
            defer { state.started = true }
            return (state.name, !state.started)
        }
        // task-owner: one off-main configd read that fills the cache, then ends
        if start { Task.detached(priority: .utility) { _ = await Self.localHostName() } }
        return Self.hostName(localHost: cached, kernel: kernelHostName())
    }

    /// The local host name the last read off the main actor found, and
    /// whether `hostName()` has started a read.
    private static let localHost = Mutex<(started: Bool, name: String?)>((false, nil))

    /// The local host name, read off the main actor (it is configd IPC) and
    /// kept for `hostName()`.
    @concurrent static func localHostName() async -> String? {
        readLocalHostName()
    }

    /// Reads the local host name and keeps it for `hostName()`. It waits on
    /// configd, so only off-main code (`@concurrent`) calls it.
    private nonisolated static func readLocalHostName() -> String? {
        let name = SCDynamicStoreCopyLocalHostName(nil) as String?
        localHost.withLock { $0 = (true, name) }
        return name
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
