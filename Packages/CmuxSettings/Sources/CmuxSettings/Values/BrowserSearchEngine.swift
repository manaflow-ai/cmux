import Foundation

/// Default search engine the cmux browser uses for address-bar queries.
public enum BrowserSearchEngine: String, CaseIterable, Sendable, SettingCodable {
    case google, duckduckgo, bing, kagi, startpage, brave, perplexity, exa,
         yahoo, ecosia, qwant, mojeek, wikipedia, github, baidu, yandex, custom
}
