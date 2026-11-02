import CmuxNextBrowserImport
import Foundation
import Testing

/// `recovery.jsonlz4` is another program's file: a tab's 1-based `index` is any integer in it.
@Suite struct FirefoxSessionReaderTests {
    /// The mozLz4 wrapper around a block that holds the JSON as one literal run.
    private func session(_ json: String) -> Data {
        let payload = Array(json.utf8)
        var block: [UInt8] = []
        if payload.count < 15 {
            block.append(UInt8(payload.count) << 4)
        } else {
            block.append(0xF0)
            var rest = payload.count - 15
            while rest >= 255 { block.append(255); rest -= 255 }
            block.append(UInt8(rest))
        }
        var data = Data("mozLz40\0".utf8)
        withUnsafeBytes(of: UInt32(payload.count).littleEndian) { data.append(contentsOf: $0) }
        data.append(contentsOf: block + payload)
        return data
    }

    private func urls(index: String?) -> [String] {
        let field = index.map { "\"index\":\($0)," } ?? ""
        let json = """
        {"windows":[{"tabs":[{\(field)"entries":[{"url":"https://a.example/"},{"url":"https://b.example/"}]}]}]}
        """
        return FirefoxSessionReader().parse(session(json)).map(\.url.absoluteString)
    }

    @Test func theIndexSelectsTheTabsCurrentEntry() {
        #expect(urls(index: "2") == ["https://b.example/"])
        #expect(urls(index: nil) == ["https://b.example/"])
    }

    @Test func anIndexOutsideTheEntriesIsClampedNotATrap() {
        #expect(urls(index: "-9223372036854775808") == ["https://a.example/"])
        #expect(urls(index: "0") == ["https://a.example/"])
        #expect(urls(index: "9223372036854775807") == ["https://b.example/"])
    }
}
