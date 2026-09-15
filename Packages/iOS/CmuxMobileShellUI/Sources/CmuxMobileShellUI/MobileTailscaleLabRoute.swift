#if os(iOS) && DEBUG
import Foundation

/// Explicit sample identities, never inferred by matching IP addresses or hostnames.
/// Production discovery would supply authenticated node identity before grouping.
struct MobileTailscaleLabRoute: Identifiable {
    let id: String
    let name: String
    let addresses: [String]

    static let saved = MobileTailscaleLabRoute(
        id: "saved", name: "macbook-lab",
        addresses: ["100.101.22.10:49152", "[fd7a:115c:a1e0::10]:49152"]
    )

    static let samples = [
        saved,
        MobileTailscaleLabRoute(
            id: "personal", name: "macbook-personal",
            addresses: ["100.101.22.14:49152", "[fd7a:115c:a1e0::42]:49152"]
        ),
        MobileTailscaleLabRoute(
            id: "work", name: "macbook-work",
            addresses: ["100.101.22.24:49152", "[fd7a:115c:a1e0::54]:49152"]
        ),
    ]
}
#endif
