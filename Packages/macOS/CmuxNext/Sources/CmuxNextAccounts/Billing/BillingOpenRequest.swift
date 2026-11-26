package import Foundation

/// Where `cmux billing checkout --open` asks the page to open.
package nonisolated enum BillingOpenRequest: String, Sendable, Equatable {
    /// A cmux browser tab when the cmux browser is signed in to Stripe Link, else the default browser.
    case auto
    /// A cmux browser tab.
    case cmux
    /// The default browser.
    case `default`
    /// Nowhere: the CLI prints the URL (`--open none`, `--no-open`).
    case printOnly

    /// The CLI's word (`auto` when absent), nil for an unknown one.
    package init?(word: String?) {
        switch word ?? "auto" {
        case "auto": self = .auto
        case "cmux": self = .cmux
        case "default", "system": self = .default
        case "none", "no": self = .printOnly
        default: return nil
        }
    }
}
