/// `browser.searchEngine` for Chromium's own default search provider
/// (chrome://settings/search, Chromium's "Search … for" and image-search menu
/// rows, `chrome.search`): every profile, incognito included, gets the
/// omnibar's engine. Applied when Chromium is ready and on each change.
enum CEFDefaultSearch {
    private static var json: String?

    static func set(_ engine: BrowserSearchEngine) {
        json = engine.chromiumDefaultSearchJSON
        apply()
    }

    static func apply() {
        let runtime = CEFRuntime.shared
        guard runtime.state == .ready, let shim = runtime.shim else { return }
        if let json {
            shim.setDefaultSearch(json)
        } else {
            shim.setDefaultSearch(nil)
        }
    }
}

extension CEFEngine {
    /// Makes `engine` Chromium's default search provider in every profile
    /// (Google: Chromium's own prepopulated Google).
    public func setDefaultSearch(_ engine: BrowserSearchEngine) {
        CEFDefaultSearch.set(engine)
    }
}
