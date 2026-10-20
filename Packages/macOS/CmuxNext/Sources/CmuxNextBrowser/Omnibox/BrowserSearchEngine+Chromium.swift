import Foundation

extension BrowserSearchEngine {
    /// Chromium's `default_search_provider_data.template_url_data` for this
    /// engine as JSON, or nil to keep Chromium's own default (Google).
    var chromiumDefaultSearchJSON: String? { nil }
}
