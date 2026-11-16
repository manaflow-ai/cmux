import CmuxNextIcons
import Foundation

/// The omnibar's leading page-info button, following Chromium's location
/// icon (`LocationIconView`, `LocationBarModelImpl::GetVectorIcon` and
/// `GetSecureDisplayText`).
public nonisolated struct PageInfoIndicator: Hashable, Sendable {
    /// Text shown next to the icon while the omnibox is not being
    /// edited ("verbose state").
    public enum Label: Hashable, Sendable {
        case notSecure
        case dangerous
        case file
        /// The product name (cmux), for internal pages.
        case product
        /// An extension keyword session: the extension's name.
        case keyword(String)
        /// The site's JavaScript is blocked (Page Info's JavaScript row, or an extension).
        case javaScriptOff
        /// An insecure site whose JavaScript is blocked: both, so "Not secure" never hides.
        case notSecureJavaScriptOff
    }

    /// How loud the chip is. `danger` uses the theme's ANSI red
    /// (`Palette.danger`).
    public enum Tone: Hashable, Sendable {
        case neutral
        case danger
    }

    /// The icon: a pack name (`browser.omnibox.pageinfo`, drawn from Chromium's icons) or an SF
    /// Symbol name, as `NSImage.icon(symbol:size:)` resolves it.
    public var symbol: String
    public var label: Label?
    public var tone: Tone
    /// Clicking opens the page info bubble. False while the user edits the
    /// text or the omnibox is empty (Chromium `IsEditingOrEmpty`).
    public var isTriggerable: Bool

    public init(symbol: String, label: Label? = nil, tone: Tone = .neutral, isTriggerable: Bool) {
        self.symbol = symbol
        self.label = label
        self.tone = tone
        self.isTriggerable = isTriggerable
    }

    /// Symbols. Secure pages show the tune icon, not a lock.
    public static let secureSymbol = IconName.browserOmniboxPageinfo.rawValue
    public static let notSecureSymbol = IconName.browserOmniboxNotsecure.rawValue
    public static let dangerousSymbol = IconName.browserOmniboxDangerous.rawValue
    public static let fileSymbol = "doc"
    public static let productSymbol = "terminal"
    public static let extensionPageSymbol = IconName.browserToolbarExtensions.rawValue
    public static let searchSymbol = IconName.browserOmniboxSearch.rawValue
    /// Page Info's JavaScript row icon, for a secure site whose JavaScript is blocked.
    public static let javaScriptOffSymbol = "curlybraces"

    /// The button for `site`.
    ///
    /// - Parameters:
    ///   - isFocused: the omnibox has keyboard focus. The security icon
    ///     stays while focused, but the text label hides.
    ///   - editingSymbol: the icon the omnibox shows for the user's own
    ///     input (search, or the selected suggestion's kind). Non-nil while
    ///     user input is in progress: the icon then describes the input, not
    ///     the page, and does not open page info.
    ///   - javaScriptBlocked: the site's JavaScript setting is block. A web
    ///     page then says "JavaScript off" (after "Not secure" on an insecure
    ///     one); a dangerous page keeps its warning. False changes nothing.
    public static func resolve(site: PageInfoSite, isFocused: Bool, editingSymbol: String?, javaScriptBlocked: Bool = false) -> PageInfoIndicator {
        if let editingSymbol {
            return PageInfoIndicator(symbol: editingSymbol, isTriggerable: false)
        }
        var indicator = pageIndicator(for: site)
        if javaScriptBlocked { indicator = javaScriptOff(indicator, site: site) }
        if isFocused { indicator.label = nil }
        return indicator
    }

    /// The button for the omnibar's current presentation.
    public static func resolve(site: PageInfoSite, chip: OmnibarPresentation.Chip, javaScriptBlocked: Bool = false) -> PageInfoIndicator {
        switch chip {
        case .input(let symbol): resolve(site: site, isFocused: true, editingSymbol: symbol)
        case .page: resolve(site: site, isFocused: false, editingSymbol: nil, javaScriptBlocked: javaScriptBlocked)
        case .keyword(let name): PageInfoIndicator(symbol: PageInfoIndicator.extensionPageSymbol, label: .keyword(name), isTriggerable: false)
        case .engineKeyword(let label): PageInfoIndicator(symbol: PageInfoIndicator.searchSymbol, label: .keyword(label), isTriggerable: false)
        }
    }

    private static func javaScriptOff(_ indicator: PageInfoIndicator, site: PageInfoSite) -> PageInfoIndicator {
        guard case .web(let connection) = site.kind else { return indicator }
        var off = indicator
        switch connection {
        case .secure:
            off.symbol = javaScriptOffSymbol
            off.label = .javaScriptOff
        case .insecure, .mixedContent:
            off.label = .notSecureJavaScriptOff
        case .certificateError, .dangerous:
            break
        }
        return off
    }

    private static func pageIndicator(for site: PageInfoSite) -> PageInfoIndicator {
        switch site.kind {
        case .empty:
            return PageInfoIndicator(symbol: PageInfoIndicator.searchSymbol, isTriggerable: false)
        case .web(let connection):
            switch connection {
            case .secure:
                return PageInfoIndicator(symbol: PageInfoIndicator.secureSymbol, isTriggerable: true)
            case .insecure, .mixedContent:
                return PageInfoIndicator(symbol: PageInfoIndicator.notSecureSymbol, label: .notSecure, isTriggerable: true)
            case .certificateError:
                return PageInfoIndicator(symbol: PageInfoIndicator.dangerousSymbol, label: .notSecure, tone: .danger, isTriggerable: true)
            case .dangerous:
                return PageInfoIndicator(symbol: PageInfoIndicator.dangerousSymbol, label: .dangerous, tone: .danger, isTriggerable: true)
            }
        case .file:
            return PageInfoIndicator(symbol: PageInfoIndicator.fileSymbol, label: .file, isTriggerable: true)
        case .internalPage, .viewSource, .devTools:
            return PageInfoIndicator(symbol: PageInfoIndicator.productSymbol, label: .product, isTriggerable: true)
        case .extensionPage:
            return PageInfoIndicator(symbol: PageInfoIndicator.extensionPageSymbol, isTriggerable: true)
        }
    }
}
