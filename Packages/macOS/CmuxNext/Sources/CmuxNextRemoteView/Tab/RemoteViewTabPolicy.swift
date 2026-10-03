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
public nonisolated enum RemoteViewTabPolicy {
    /// The loopback host names a phase-1 tab may connect to.
    public static let loopbackNames: Set<String> = ["mock", "local", "localhost"]

    public static func decide(
        record: RemoteViewTabRecord?,
        source: RemoteViewTabSource,
        paneAvailable: Bool = RemoteViewAvailability.isAvailable
    ) -> RemoteViewTabDecision {
        if source == .remoteTree { return .unavailable(.remoteRecord) }
        guard let record else { return .unavailable(.invalidAddress) }
        guard paneAvailable else { return .unavailable(.notInThisBuild) }
        guard isLoopback(record.host) else { return .unavailable(.notLoopback(host: record.host)) }
        guard source == .person else {
            // A confirmed tab starts in view mode; control is the person's toggle.
            var view = record
            view.mode = .view
            return .confirm(view)
        }
        return .connect(record)
    }

    /// `mock`, `local`, `localhost` (any case) or a dotted IPv4 address in
    /// 127.0.0.0/8. Names that only resolve to loopback do not count.
    public static func isLoopback(_ host: String) -> Bool {
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
