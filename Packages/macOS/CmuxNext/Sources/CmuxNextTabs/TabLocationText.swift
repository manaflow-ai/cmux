import CoreGraphics

/// Fits a location's host and dimmed rest into the field's text width
/// (plain logic, `measure` injected so tests need no font). The host is
/// what tells the user which site this is, so it is never cut in the middle:
///
/// 1. Both fit: shown whole.
/// 2. The host fits: the rest is cut at its tail (`/a/b/c…`).
/// 3. The host alone does not fit: the rest is dropped and the host is cut
///    at its head (`…secure-login.example.net`), keeping the registrable
///    end visible, so `paypal.com.secure-login.example.net` never reads as
///    `paypal.com…`.
enum TabLocationText {
    static let ellipsis = "…"

    static func fit(host: String, rest: String, width: CGFloat,
                    measure: (String) -> CGFloat) -> (host: String, rest: String) {
        if measure(host + rest) <= width { return (host, rest) }
        if measure(host) <= width {
            let kept = longest(Array(rest), fits: { measure(host + String($0) + ellipsis) <= width })
            return (host, kept.isEmpty ? "" : String(kept) + ellipsis)
        }
        let characters = Array(host)
        let count = longestCount(characters.count) { n in
            measure(ellipsis + String(characters.suffix(n))) <= width
        }
        return (ellipsis + String(characters.suffix(count)), "")
    }

    /// The longest prefix of `characters` that `fits`.
    private static func longest(_ characters: [Character], fits: ([Character]) -> Bool) -> [Character] {
        Array(characters.prefix(longestCount(characters.count) { fits(Array(characters.prefix($0))) }))
    }

    /// The largest n in 0...upper with `fits(n)`, for a `fits` that holds up
    /// to some n and fails after it (binary search).
    private static func longestCount(_ upper: Int, fits: (Int) -> Bool) -> Int {
        var low = 0
        var high = upper
        while low < high {
            let mid = (low + high + 1) / 2
            if fits(mid) { low = mid } else { high = mid - 1 }
        }
        return low
    }
}
