import Foundation

/// The one decision for every `remote_view` tab (plans/cmux-next/
/// remote-desktop.md 11.0). Pure, so tests cover every build's rules.
/// Phase 1 (until the host verifies link tokens):
/// - a record from a remote tree never opens, in every build;
/// - builds without the pane show "not available";
/// - a development build connects only to a loopback host (`mock`, `local`,
///   `localhost`, `127.0.0.0/8`);
/// - a record no person confirmed (agents, scripts, restore) asks first,
///   and Connect starts view mode: automation never starts a session or
///   asks for control by itself.
/// The names `mock`, `local` and `localhost` are reserved: the transport
/// connects to a literal 127.0.0.1 for them and never resolves them through
/// the machine directory or DNS.
public struct RemoteViewTabPolicy {
    public init() {}
    /// The loopback host names a phase-1 tab may connect to.
    public let loopbackNames: Set<String> = ["mock", "local", "localhost"]

    public func decide(
        record: RemoteViewTabRecord?,
        source: RemoteViewTabSource,
        paneAvailable: Bool = RemoteViewAvailability().isAvailable
    ) -> RemoteViewTabDecision {
        if source == .remoteTree { return .unavailable(.remoteRecord) }
        guard let record else { return .unavailable(.invalidAddress) }
        guard paneAvailable else { return .unavailable(.notInThisBuild) }
        if record.cloudDesktop {
            // A Cloud machine's desktop goes only over the app's own Cloud tunnel to the machine
            // the signed-in account owns (its private address, the hub's client token), never to
            // a network address the record names.
        } else if record.vncPort != nil {
            // An RFB host authenticates the viewer itself (its own password),
            // so the phase-1 loopback rule does not apply; its stream is not
            // encrypted, so it stays on private networks.
            guard isPrivateNetwork(record.host) else { return .unavailable(.notPrivateNetwork(host: record.host)) }
        } else {
            guard isLoopback(record.host) else { return .unavailable(.notLoopback(host: record.host)) }
        }
        guard source == .person else {
            // A confirmed tab starts in view mode; control is the person's toggle.
            var view = record
            view.mode = .view
            return .confirm(view)
        }
        return .connect(record)
    }

    /// Where a VNC tab may connect: loopback, the tailnet (100.64.0.0/10 and
    /// `*.ts.net` names), private IPv4 (10/8, 172.16/12, 192.168/16), link-local
    /// `*.local` names, and single-label names (resolved by the LAN or
    /// MagicDNS search domain, never by public DNS).
    public func isPrivateNetwork(_ host: String) -> Bool {
        if isLoopback(host) { return true }
        let lower = host.lowercased()
        if let octets = ipv4Octets(lower) {
            switch (octets[0], octets[1]) {
            case (10, _), (192, 168): return true
            case (172, 16...31): return true
            case (100, 64...127): return true
            default: return false
            }
        }
        if lower.hasSuffix(".ts.net") || lower.hasSuffix(".local") { return true }
        // A dotless all-digit or 0x name is a numeric IPv4 address to the
        // resolver (134744072 is 8.8.8.8), not a LAN name.
        if lower.utf8.allSatisfy({ (0x30...0x39).contains($0) }) || lower.hasPrefix("0x") { return false }
        return !lower.contains(".")
    }

    /// The four octets of a dotted IPv4 address (no leading zeros), else nil.
    private func ipv4Octets(_ host: String) -> [UInt8]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let octets = parts.compactMap { part -> UInt8? in
            guard (1...3).contains(part.count), part.utf8.allSatisfy({ (0x30...0x39).contains($0) }),
                  part.count == 1 || part.first != "0" else { return nil }
            return UInt8(part)
        }
        return octets.count == 4 ? octets : nil
    }

    /// `mock`, `local`, `localhost` (any case) or a dotted IPv4 address in
    /// 127.0.0.0/8. Names that only resolve to loopback do not count.
    public func isLoopback(_ host: String) -> Bool {
        if loopbackNames.contains(host.lowercased()) { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        let octets = parts.compactMap { part -> UInt8? in
            guard (1...3).contains(part.count), part.utf8.allSatisfy({ (0x30...0x39).contains($0) }),
                  part.count == 1 || part.first != "0" else { return nil }
            return UInt8(part)
        }
        return octets.count == 4 && octets[0] == 127
    }
}
