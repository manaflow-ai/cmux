public import Foundation

/// Chromium's own autofill pages, which Settings > Browser > Autofill and passwords, the palette
/// and a browser profile's menu open in a Chromium tab of a browser profile (Lawrence 2026-10-28:
/// "use native chrome UIs and functionality"). Each page edits the profile's real store: the
/// passwords the save prompt writes, and the addresses, phone numbers and emails autofill fills.
public nonisolated enum ChromiumAutofillPage: String, CaseIterable, Sendable {
    /// Google Password Manager's WebUI: saved passwords, passkeys, checkup, import and export
    /// (reveal and export ask for the Mac's password or Touch ID first, as in Chrome).
    case passwords = "chrome://password-manager/passwords"
    /// Chrome's Addresses and more: saved addresses, phone numbers and email addresses.
    case addresses = "chrome://settings/addresses"

    /// The page's address.
    public var url: URL {
        // The raw values are literal chrome:// URLs, which always parse.
        URL(string: rawValue) ?? URL(fileURLWithPath: "/dev/null")
    }
}
