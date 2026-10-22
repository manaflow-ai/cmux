import Foundation

/// The open rule of `cmux billing checkout|portal` (paid-product-DESIGN.md
/// section 4). The cmux browser is used only while it is on; the default
/// browser only while it is not cmux itself (it would come back here).
nonisolated struct BillingCheckoutOpener: Sendable {
    /// macOS opens web links with this cmux.
    let defaultBrowserIsCmux: Bool
    /// `browser.enabled`.
    let cmuxBrowserEnabled: Bool

    func decide(_ request: BillingOpenRequest, linkSession: Bool) -> BillingOpenTarget {
        let wanted: BillingOpenTarget = switch request {
        case .printOnly: .nowhere
        case .cmux: .cmuxBrowser
        case .default: .defaultBrowser
        case .auto: linkSession ? .cmuxBrowser : .defaultBrowser
        }
        switch wanted {
        case .cmuxBrowser where !cmuxBrowserEnabled: return .defaultBrowser
        case .defaultBrowser where defaultBrowserIsCmux && cmuxBrowserEnabled: return .cmuxBrowser
        default: return wanted
        }
    }
}
