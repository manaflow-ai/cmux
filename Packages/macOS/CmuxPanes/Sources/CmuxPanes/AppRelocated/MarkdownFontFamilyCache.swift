import CoreText
import Foundation

/// Caches installed markdown viewer font families after enumerating them off
/// the main thread.
actor MarkdownFontFamilyCache {
    private var cached: [String]?

    func families() async -> [String] {
        if let cached { return cached }
        let names = await Task.detached(priority: .userInitiated) { () -> [String] in
            let raw = (CTFontManagerCopyAvailableFontFamilyNames() as? [String]) ?? []
            return raw
                .filter { !$0.hasPrefix(".") }
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        }.value
        cached = names
        return names
    }
}
