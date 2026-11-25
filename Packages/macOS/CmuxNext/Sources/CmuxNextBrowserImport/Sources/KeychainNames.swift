import CmuxNextCompat
import Foundation

/// One detection's view of the Keychain's browser storage items: listed at
/// most once, and only when a Chromium browser on disk has no confirmed item.
/// Fills in the item a registry row does not name, names wrongly, or that a
/// folder found by discovery uses. Names only; no password is read.
final class KeychainNames {
    private let list: @Sendable () -> [SafeStorageName]
    private var names: [SafeStorageName]?

    init(_ list: @escaping @Sendable () -> [SafeStorageName]) {
        self.list = list
    }

    /// `browser` with the Keychain item its storage key is in, when the
    /// Keychain lists one that fits; else `browser` as it is.
    func completing(_ browser: ImportBrowser, home: URL) -> ImportBrowser {
        guard browser.family == .chromium, var row = browser.row, row.safeStorage?.confirmed != true,
              row.dataDirectories.contains(where: { FileManager.checked.fileExists(atPath: home.appending(path: $0).path) }) else { return browser }
        let names = names ?? list()
        self.names = names
        guard let item = Self.item(for: row, in: names), item != row.safeStorage else { return browser }
        row.safeStorage = item
        return ImportBrowser(row: row)
    }

    /// The listed item that fits `row`: its own service first, then one
    /// named after the product, an app name or its data folder.
    static func item(for row: BrowserSourceRow, in names: [SafeStorageName]) -> SafeStorageItem? {
        let generic: Set<String> = ["Library", "Application Support", "User Data", "browser-data", "host"]
        let stems = [row.name] + (row.appNames ?? []) + row.dataDirectories.flatMap { $0.split(separator: "/").map(String.init) }
            .filter { !generic.contains($0) }
        let wanted = [row.safeStorage?.service].compactMap { $0 } + stems.flatMap { ["\($0) Safe Storage", "\($0) Storage Key"] }
        for candidate in wanted {
            let matching = names.filter { $0.service.caseInsensitiveCompare(candidate) == .orderedSame }
            guard let service = matching.first?.service else { continue }
            let accounts = matching.compactMap(\.account)
            let stem = service.replacingOccurrences(of: " Safe Storage", with: "")
            // Chromium names the account after the product; Electron adds " Key".
            let preferred = row.profiles == .dataDirectory ? "\(stem) Key" : stem
            let account: String? = if let own = row.safeStorage?.account, accounts.isEmpty || accounts.contains(own) {
                own
            } else if accounts.count > 1, accounts.contains(preferred) {
                preferred
            } else {
                nil
            }
            return SafeStorageItem(service: service, account: account, confirmed: true)
        }
        return nil
    }
}
