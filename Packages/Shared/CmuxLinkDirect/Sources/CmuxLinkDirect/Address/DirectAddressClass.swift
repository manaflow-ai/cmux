/// What kind of network an address belongs to, which decides when a route
/// to it can work (b4-direct.md section 5).
public enum DirectAddressClass: String, Sendable, Hashable, CaseIterable {
    case loopback
    /// Tailscale: `100.64.0.0/10`, `fd7a:115c:a1e0::/48`, MagicDNS `*.ts.net`.
    case tailscale
    /// Private, link-local or ULA ranges and `*.local` names (LAN, or a
    /// WireGuard route to such a subnet).
    case privateNetwork
    /// Anything else: public addresses and other DNS names.
    case publicNetwork
}
