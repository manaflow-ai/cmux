import CmuxNextBrowserImport
import Compression
import Foundation
import Testing

/// Search Engines from Firefox and Safari: Firefox's default engine (one the
/// person added keeps its addresses, one Firefox ships maps to its address)
/// and Safari's Search setting, then the same built-in or custom mapping as Chromium's.
@Suite struct FirefoxSafariSearchEngineTests {
    private static let builtIn = ["google": "https://www.google.com/search?q={searchTerms}",
                                  "duckduckgo": "https://duckduckgo.com/?q={searchTerms}"]

    /// A profile folder holding `json` as `search.json.mozlz4` (mozLz4: magic, size, one raw LZ4 block).
    private static func firefoxProfile(_ json: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "firefox-search-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let input = [UInt8](json.utf8)
        var block = [UInt8](repeating: 0, count: input.count + 1024)
        let written = compression_encode_buffer(&block, block.count, input, input.count, nil, COMPRESSION_LZ4_RAW)
        var file = Array("mozLz40\0".utf8)
        withUnsafeBytes(of: UInt32(input.count).littleEndian) { file += $0 }
        file += block.prefix(written)
        try Data(file).write(to: folder.appending(path: "search.json.mozlz4"))
        return folder
    }

    @Test func anEngineAddedInFirefoxKeepsItsAddresses() throws {
        let folder = try Self.firefoxProfile(#"""
        {"version":10,"engines":[{"id":"google","_name":"Google","_isAppProvided":true},
          {"id":"a1","_name":"Kagi","_definedAliases":["@kagi"],"_urls":[
            {"template":"https://kagi.com/search","params":[{"name":"q","value":"{searchTerms}"},{"name":"l","value":"{moz:locale}"}]},
            {"type":"application/x-suggestions+json","template":"https://kagi.com/api/autosuggest?q={searchTerms}","params":[]}]}],
         "metaData":{"defaultEngineId":"a1","appDefaultEngineId":"google"}}
        """#)
        defer { try? FileManager.default.removeItem(at: folder) }
        let engine = try #require(FirefoxSearchEngineReader().read(profile: folder))
        #expect(engine.name == "Kagi")
        #expect(engine.keyword == "@kagi")
        #expect(engine.search == "https://kagi.com/search?q={searchTerms}")
        #expect(engine.suggest == "https://kagi.com/api/autosuggest?q={searchTerms}")
        #expect(engine.setting(builtIn: Self.builtIn).engine == "custom")
    }

    @Test func anEngineFirefoxShipsMapsToTheBuiltIn() throws {
        let current = try Self.firefoxProfile(#"{"engines":[{"id":"ddg","_name":"DuckDuckGo","_isAppProvided":true}],"metaData":{"defaultEngineId":"ddg"}}"#)
        let older = try Self.firefoxProfile(#"{"engines":[{"_name":"Google","_isAppProvided":true}],"metaData":{"current":"Google"}}"#)
        let unset = try Self.firefoxProfile(#"{"engines":[{"id":"google","_name":"Google"}],"metaData":{}}"#)
        defer { for folder in [current, older, unset] { try? FileManager.default.removeItem(at: folder) } }
        #expect(FirefoxSearchEngineReader().read(profile: current)?.setting(builtIn: Self.builtIn).engine == "duckduckgo")
        #expect(FirefoxSearchEngineReader().read(profile: older)?.setting(builtIn: Self.builtIn).engine == "google")
        #expect(FirefoxSearchEngineReader().read(profile: unset) == nil)
    }

    @Test func safarisSearchSettingMapsToTheBuiltIn() {
        let reader = SafariSearchEngineReader()
        let duck: [String: Any] = ["NSWebServicesProviderWebSearch": ["NSDefaultDisplayName": "DuckDuckGo", "NSProviderIdentifier": "com.duckduckgo"]]
        #expect(reader.read(duck)?.setting(builtIn: Self.builtIn).engine == "duckduckgo")
        let ecosia: [String: Any] = ["NSWebServicesProviderWebSearch": ["NSProviderIdentifier": "org.ecosia.www"]]
        #expect(reader.read(ecosia)?.search == "https://www.ecosia.org/search?q={searchTerms}")
        #expect(reader.read(nil) == nil)
        #expect(reader.read(["NSWebServicesProviderWebSearch": ["NSDefaultDisplayName": "Unknown"]]) == nil)
    }
}
