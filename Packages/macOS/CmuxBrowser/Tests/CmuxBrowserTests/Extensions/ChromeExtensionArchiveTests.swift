import Compression
import Foundation
import Testing

@testable import CmuxBrowser

@Suite struct ChromeExtensionArchiveTests {
    /// Builds a one-file zip whose headers declare `declaredSize` bytes.
    static func zip(name: String, payload: Data, method: UInt16, declaredSize: Int, externalAttributes: UInt32 = 0o100644 << 16) -> Data {
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xff), UInt8((v >> 8) & 0xff)] }
        func le32(_ v: Int) -> [UInt8] { le16(v & 0xffff) + le16((v >> 16) & 0xffff) }
        let nameBytes = Array(name.utf8)
        var local: [UInt8] = le32(0x0403_4b50) + le16(20) + le16(0) + le16(Int(method)) + le16(0) + le16(0)
        local += le32(0) + le32(payload.count) + le32(declaredSize) + le16(nameBytes.count) + le16(0) + nameBytes
        var central: [UInt8] = le32(0x0201_4b50) + le16(20) + le16(20) + le16(0) + le16(Int(method)) + le16(0) + le16(0)
        central += le32(0) + le32(payload.count) + le32(declaredSize) + le16(nameBytes.count) + le16(0) + le16(0)
        central += le16(0) + le16(0) + le32(Int(externalAttributes)) + le32(0) + nameBytes
        let directoryOffset = local.count + payload.count
        let end: [UInt8] = le32(0x0605_4b50) + le16(0) + le16(0) + le16(1) + le16(1) + le32(central.count) + le32(directoryOffset) + le16(0)
        return Data(local) + payload + Data(central) + Data(end)
    }

    static func deflate(_ data: Data) -> Data {
        let capacity = data.count + 1024
        var out = Data(count: capacity)
        let written = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_encode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    src.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        return out.prefix(written)
    }

    private func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("cmux-zip-test-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func stopsAnEntryThatExpandsPastItsDeclaredSize() throws {
        let bomb = Self.deflate(Data(count: 1024 * 1024))
        let archive = Self.zip(name: "manifest.json", payload: bomb, method: 8, declaredSize: 10)
        let output = scratch()
        defer { try? FileManager.default.removeItem(at: output) }
        #expect(throws: ChromeExtensionPackage.Failure.self) {
            try ChromeExtensionArchive.extract(archive, into: output, byteBudget: 1 << 30, fileManager: .default)
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: output.appendingPathComponent("manifest.json").path)[.size] as? Int) ?? 0
        #expect(size <= 64 * 1024)
    }

    @Test func refusesSymbolicLinkEntries() {
        let link = Self.zip(name: "evil", payload: Data("/etc".utf8), method: 0, declaredSize: 4, externalAttributes: 0o120777 << 16)
        #expect(throws: ChromeExtensionPackage.Failure.self) {
            try ChromeExtensionArchive.extract(link, into: scratch(), byteBudget: 1 << 20, fileManager: .default)
        }
    }

    @Test func extractsStoredAndDeflatedEntries() throws {
        let text = Data(String(repeating: "{\"a\":1}", count: 200).utf8)
        let deflated = Self.zip(name: "manifest.json", payload: Self.deflate(text), method: 8, declaredSize: text.count)
        let output = scratch()
        defer { try? FileManager.default.removeItem(at: output) }
        try ChromeExtensionArchive.extract(deflated, into: output, byteBudget: 1 << 20, fileManager: .default)
        #expect(try Data(contentsOf: output.appendingPathComponent("manifest.json")) == text)
    }
}
