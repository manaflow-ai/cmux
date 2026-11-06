public import Foundation

extension CloudMachineSecrets {
    /// The names `index` (``index(from:)``) holds values for, each once and sorted, whatever their
    /// scope: what the Chief card's Vault section lists (cmux issue 34263). Names only, never a value.
    public static func names(in index: [String: Int64]) -> [String] {
        Set(index.keys.compactMap { account in
            account.lastIndex(of: "/").map { String(account[account.index(after: $0)...]) }
        }).sorted()
    }

    /// This Mac's index, `~/.config/cmux/cloud-secrets.json`, which `cmux cloud secret set` writes.
    public static func indexURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".config/cmux/cloud-secrets.json")
    }
}
