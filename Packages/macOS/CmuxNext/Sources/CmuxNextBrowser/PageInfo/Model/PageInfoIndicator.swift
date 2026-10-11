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
    }

    /// How loud the chip is. `danger` uses the theme's ANSI red
    /// (`Palette.danger`).
    public enum Tone: Hashable, Sendable {
        case neutral
        case danger
    }

    /// SF Symbol name.
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
    public static let secureSymbol = "slider.horizontal.3"
    public static let notSecureSymbol = "exclamationmark.triangle"
    public static let dangerousSymbol = "exclamationmark.triangle.fill"
    public static let fileSymbol = "doc"
    public static let productSymbol = "terminal"
    public static let extensionPageSymbol = "puzzlepiece.extension"
    public static let searchSymbol = "magnifyingglass"

    /// The button for `site`.
    ///
    /// - Parameters:
    ///   - isFocused: the omnibox has keyboard focus. The security icon
    ///     stays while focused, but the text label hides.
    ///   - editingSymbol: the icon the omnibox shows for the user's own
    ///     input (search, or the selected suggestion's kind). Non-nil while
    ///     user input is in progress: the icon then describes the input, not
    ///     the page, and does not open page info.
    public static func resolve(site: PageInfoSite, isFocused: Bool, editingSymbol: String?) -> PageInfoIndicator {
        if let editingSymbol {
            return PageInfoIndicator(symbol: editingSymbol, isTriggerable: false)
        }
        var indicator = pageIndicator(for: site)
        if isFocused { indicator.label = nil }
        return indicator
    }

    /// The button for the omnibar's current presentation.
    public static func resolve(site: PageInfoSite, chip: OmnibarPresentation.Chip) -> PageInfoIndicator {
        switch chip {
        case .input(let symbol): resolve(site: site, isFocused: true, editingSymbol: symbol)
        case .page(let focused): resolve(site: site, isFocused: focused, editingSymbol: nil)
        case .keyword(let name): PageInfoIndicator(symbol: PageInfoIndicator.extensionPageSymbol, label: .keyword(name), isTriggerable: false)
        }
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
