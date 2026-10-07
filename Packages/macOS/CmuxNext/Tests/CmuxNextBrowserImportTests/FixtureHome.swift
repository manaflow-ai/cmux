import Compression
import Foundation
import SQLite3
@testable import CmuxNextBrowserImport

/// A throwaway home folder with fixture browser profiles. Tests never read
/// the real user's browser data.
final class FixtureHome {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "cmux-import-fixture-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    var environment: ImportEnvironment { ImportEnvironment(homeDirectory: url, locateApp: { _ in nil }) }

    func directory(_ browser: ImportBrowser) -> URL { url.appending(path: browser.dataDirectory, directoryHint: .isDirectory) }

    @discardableResult
    func write(_ text: String, to file: URL) throws -> URL {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
        return file
    }

    func write(_ data: Data, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
    }

    /// A Chromium user data dir with `Local State` naming `profiles`.
    func chromium(_ browser: ImportBrowser, profiles: [(dir: String, name: String)]) throws -> URL {
        let root = directory(browser)
        let cache = profiles.map { "\"\($0.dir)\": {\"name\": \"\($0.name)\"}" }.joined(separator: ",")
        try write(#"{"profile": {"info_cache": {\#(cache)}}}"#, to: root.appending(path: "Local State"))
        for profile in profiles {
            try write("{}", to: root.appending(path: profile.dir).appending(path: "Preferences"))
        }
        return root
    }

    static func sqlite(_ file: URL, _ statements: [String]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        guard sqlite3_open(file.path, &db) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        defer { sqlite3_close(db) }
        for sql in statements {
            var error: UnsafeMutablePointer<CChar>?
            guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
                let message = error.map { String(cString: $0) } ?? "?"
                sqlite3_free(error)
                throw NSError(domain: "sqlite", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(message): \(sql)"])
            }
        }
    }

    /// mozLz4: magic, uint32 size, raw LZ4 block.
    static func mozLz4(_ json: String) -> Data {
        let input = [UInt8](json.utf8)
        var output = [UInt8](repeating: 0, count: input.count + 1024)
        let written = compression_encode_buffer(&output, output.count, input, input.count, nil, COMPRESSION_LZ4_RAW)
        var data = Data("mozLz40\0".utf8)
        withUnsafeBytes(of: UInt32(input.count).littleEndian) { data.append(contentsOf: $0) }
        data.append(contentsOf: output[0..<written])
        return data
    }
}

/// Builds SNSS session files command by command.
struct SNSSWriter {
    private(set) var data = Data("SNSS".utf8) + le32(1)

    static func le32(_ value: Int32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }

    mutating func command(_ id: UInt8, _ payload: Data) {
        withUnsafeBytes(of: UInt16(payload.count + 1).littleEndian) { data.append(contentsOf: $0) }
        data.append(id)
        data.append(payload)
    }

    static func pad(_ data: Data) -> Data { data + Data(count: (4 - data.count % 4) % 4) }

    mutating func navigation(tab: Int32, index: Int32, url: String, title: String) {
        var body = Self.le32(tab) + Self.le32(index)
        body += Self.le32(Int32(url.utf8.count)) + Self.pad(Data(url.utf8))
        let units = Array(title.utf16)
        body += Self.le32(Int32(units.count)) + Self.pad(Data(units.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }))
        command(6, Self.le32(Int32(body.count)) + body)
    }

    mutating func raw(_ id: UInt8, _ values: Int32...) { command(id, values.reduce(Data()) { $0 + Self.le32($1) }) }
}
