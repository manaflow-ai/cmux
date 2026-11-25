import Foundation

/// Who can reach a web link, as the Rust classifier (`link_open_side` in
/// cmux-mobile-link-ffi) decides from its address.
public enum TerminalLinkReach: Equatable, Sendable {
    /// A public address: this iPhone reaches it as well as the Mac does.
    case phone
    /// An address only the Mac reaches: loopback, a LAN or tailnet host, a bare host name.
    case mac
    /// Not a web page (`javascript:`, `file:`, an app's scheme, no host).
    case notWeb
}

/// How the person opened a web link in a terminal on this iPhone.
public enum TerminalLinkAction: Equatable, Sendable {
    /// A tap on the link in the terminal's rows.
    case tap
    /// Open Link in the long-press menu.
    case openLink
    /// Open on iPhone in the long-press menu.
    case openOnPhone
    /// Open on Mac in the long-press menu: a cmux browser tab beside the terminal on the
    /// Mac (the Mac's Cmd-click).
    case openOnMac
    /// Open in Safari in the long-press menu.
    case openInSafari
}

/// Where a web link opened from a terminal on this iPhone goes.
public enum TerminalLinkDestination: Equatable, Sendable {
    /// A Safari view over the terminal, on this iPhone (Safari's passkeys, AutoFill and
    /// cookies; Done comes back to the terminal).
    case phone(URL)
    /// Safari, or the default browser, on this iPhone.
    case systemBrowser(URL)
    /// A cmux browser tab beside the terminal on the Mac.
    case mac(URL)
    /// Nothing opens: not a web page.
    case none
}

/// Decides where a terminal's web link opens: a tap opens it where it can be reached
/// (a public page on this iPhone, a page only the Mac reaches on the Mac), and the
/// long-press menu offers the other device.
///
/// ```swift
/// let route = TerminalLinkRoute(opensOnMac: true)
/// route.destination(for: github, reach: .phone, action: .tap)     // .phone(github)
/// route.destination(for: localhost, reach: .mac, action: .tap)    // .mac(localhost)
/// route.otherDevice(for: .phone)                                  // .openOnMac
/// ```
public struct TerminalLinkRoute: Equatable, Sendable {
    /// The terminal's workspace can open a browser tab on its Mac.
    public var opensOnMac: Bool

    public init(opensOnMac: Bool) {
        self.opensOnMac = opensOnMac
    }

    public func destination(for url: URL, reach: TerminalLinkReach, action: TerminalLinkAction) -> TerminalLinkDestination {
        if reach == .notWeb { return .none }
        switch action {
        case .openInSafari: return .systemBrowser(url)
        case .openOnPhone: return .phone(url)
        case .openOnMac: return opensOnMac ? .mac(url) : .phone(url)
        case .tap, .openLink: return reach == .mac && opensOnMac ? .mac(url) : .phone(url)
        }
    }

    /// The long-press menu's row for the device a tap does not open the link on.
    public func otherDevice(for reach: TerminalLinkReach) -> TerminalLinkAction? {
        guard opensOnMac else { return nil }
        switch reach {
        case .phone: return .openOnMac
        case .mac: return .openOnPhone
        case .notWeb: return nil
        }
    }
}
