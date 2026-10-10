import Foundation

/// One row of the browser table: name, family, bundle ids, data folder and,
/// for Chromium browsers, the Keychain item that holds the cookie key.
struct BrowserCatalogEntry: Sendable {
    var name: String
    var family: BrowserFamily
    var bundleIDs: [String]
    var dataDirectory: String
    var safeStorage: String?
    var rootProfile = false
}

/// Every browser cmux looks for, by bundle id and data folder. Keychain
/// service names follow each browser's `kKeychainServiceName`; the ones not
/// confirmed against a real install are marked, and a wrong name only makes
/// that browser's cookie import report "key not found".
enum BrowserCatalog {
    private static let support = "Library/Application Support/"

    static func entry(_ browser: ImportBrowser) -> BrowserCatalogEntry {
        switch browser {
        case .chrome: chromium("Google Chrome", "com.google.Chrome", "Google/Chrome", key: "Chrome")
        case .chromeBeta: chromium("Google Chrome Beta", "com.google.Chrome.beta", "Google/Chrome Beta", key: "Chrome")
        case .chromeDev: chromium("Google Chrome Dev", "com.google.Chrome.dev", "Google/Chrome Dev", key: "Chrome")
        case .chromeCanary: chromium("Google Chrome Canary", "com.google.Chrome.canary", "Google/Chrome Canary", key: "Chrome")
        case .chromium: chromium("Chromium", "org.chromium.Chromium", "Chromium", key: "Chromium")
        case .arc: chromium("Arc", "company.thebrowser.Browser", "Arc/User Data", key: "Arc")
        case .dia: chromium("Dia", "company.thebrowser.dia", "Dia/User Data", key: "Dia") // key unconfirmed
        case .comet: chromium("Comet", "ai.perplexity.comet", "Comet", key: "Comet") // key unconfirmed
        case .brave: chromium("Brave", "com.brave.Browser", "BraveSoftware/Brave-Browser", key: "Brave")
        case .braveBeta: chromium("Brave Beta", "com.brave.Browser.beta", "BraveSoftware/Brave-Browser-Beta", key: "Brave")
        case .braveNightly: chromium("Brave Nightly", "com.brave.Browser.nightly", "BraveSoftware/Brave-Browser-Nightly", key: "Brave")
        case .edge: chromium("Microsoft Edge", "com.microsoft.edgemac", "Microsoft Edge", key: "Microsoft Edge")
        case .edgeBeta: chromium("Microsoft Edge Beta", "com.microsoft.edgemac.Beta", "Microsoft Edge Beta", key: "Microsoft Edge")
        case .edgeDev: chromium("Microsoft Edge Dev", "com.microsoft.edgemac.Dev", "Microsoft Edge Dev", key: "Microsoft Edge")
        case .edgeCanary: chromium("Microsoft Edge Canary", "com.microsoft.edgemac.Canary", "Microsoft Edge Canary", key: "Microsoft Edge")
        case .vivaldi: chromium("Vivaldi", "com.vivaldi.Vivaldi", "Vivaldi", key: "Vivaldi")
        case .opera: chromium("Opera", "com.operasoftware.Opera", "com.operasoftware.Opera", key: "Opera", root: true)
        case .operaGX: chromium("Opera GX", "com.operasoftware.OperaGX", "com.operasoftware.OperaGX", key: "Opera", root: true) // key unconfirmed
        case .helium: chromium("Helium", "net.imput.helium", "net.imput.helium", key: "Helium") // key unconfirmed
        case .sidekick: chromium("Sidekick", "com.pushplaylabs.sidekick", "Sidekick", key: "Sidekick") // key unconfirmed
        case .yandex: chromium("Yandex Browser", "ru.yandex.desktop.yandex-browser", "Yandex/YandexBrowser", key: "Yandex")
        case .thorium: chromium("Thorium", "org.chromium.Thorium", "Thorium", key: "Thorium") // key unconfirmed
        case .safari:
            BrowserCatalogEntry(name: "Safari", family: .safari, bundleIDs: ["com.apple.Safari"], dataDirectory: "Library/Safari")
        case .safariTechnologyPreview:
            BrowserCatalogEntry(name: "Safari Technology Preview", family: .safari, bundleIDs: ["com.apple.SafariTechnologyPreview"],
                                dataDirectory: "Library/SafariTechnologyPreview")
        case .firefox:
            gecko("Firefox", ["org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly"], "Firefox")
        case .zen: gecko("Zen", ["app.zen-browser.zen"], "zen")
        case .floorp: gecko("Floorp", ["one.ablaze.floorp"], "Floorp")
        case .librewolf: gecko("LibreWolf", ["org.mozilla.librewolf", "io.gitlab.librewolf-community.librewolf"], "librewolf")
        case .waterfox: gecko("Waterfox", ["net.waterfox.waterfox"], "Waterfox")
        case .tor: gecko("Tor Browser", ["org.torproject.torbrowser"], "TorBrowser-Data/Browser")
        case .orion:
            BrowserCatalogEntry(name: "Orion", family: .webkit, bundleIDs: ["com.kagi.kagimacOS"], dataDirectory: support + "Orion")
        case .duckDuckGo:
            BrowserCatalogEntry(name: "DuckDuckGo", family: .webkit, bundleIDs: ["com.duckduckgo.macos.browser"],
                                dataDirectory: "Library/Containers/com.duckduckgo.macos.browser/Data/Library/Application Support")
        }
    }

    private static func chromium(_ name: String, _ bundleID: String, _ folder: String, key: String, root: Bool = false) -> BrowserCatalogEntry {
        BrowserCatalogEntry(name: name, family: .chromium, bundleIDs: [bundleID], dataDirectory: support + folder,
                            safeStorage: key + " Safe Storage", rootProfile: root)
    }

    private static func gecko(_ name: String, _ bundleIDs: [String], _ folder: String) -> BrowserCatalogEntry {
        BrowserCatalogEntry(name: name, family: .firefox, bundleIDs: bundleIDs, dataDirectory: support + folder)
    }
}
