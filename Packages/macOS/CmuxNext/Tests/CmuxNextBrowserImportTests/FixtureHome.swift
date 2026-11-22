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

