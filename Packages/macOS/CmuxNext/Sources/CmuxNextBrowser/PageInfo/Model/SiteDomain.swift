import Foundation

/// Registrable domain ("eTLD+1") without the full Public Suffix List: the
/// last two labels, or three under a common two-level suffix. Enough to
/// group a page's cookies by site; never used for a security decision.
public nonisolated enum SiteDomain {
    static let twoLevelSuffixes: Set<String> = [
        "co.uk", "org.uk", "ac.uk", "gov.uk", "com.au", "net.au", "org.au", "co.jp", "ne.jp", "or.jp",
        "co.kr", "co.nz", "com.br", "com.cn", "com.hk", "com.tw", "com.sg", "co.in", "co.za", "com.mx",
        "github.io", "vercel.app", "pages.dev", "netlify.app", "herokuapp.com", "appspot.com", "blogspot.com",
    ]

    public static func registrable(_ domain: String) -> String {
        var host = domain.lowercased()
        while host.hasPrefix(".") { host.removeFirst() }
        if host.hasSuffix(".") { host.removeLast() }
        // IP literals and single labels are their own site.
        if host.contains(":") || host.allSatisfy({ $0.isNumber || $0 == "." }) { return host }
        let labels = host.split(separator: ".")
        guard labels.count > 2 else { return host }
        let lastTwo = labels.suffix(2).joined(separator: ".")
        let take = twoLevelSuffixes.contains(lastTwo) ? 3 : 2
        return labels.suffix(take).joined(separator: ".")
    }
}
