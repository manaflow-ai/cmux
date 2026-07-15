import CryptoKit
import Foundation

extension NotesTreeStorage {
    // MARK: - Helpers

    /// True when `child` is equal to, or nested inside, `ancestor`.
    /// Containment check used by every tree mutation guard. Canonicalizes
    /// both sides (symlinks resolved) so a linked directory placed inside the
    /// tree — e.g. `.cmux/notes/<ws>/out -> ~/target` — can never authorize
    /// writes outside the notes root. Missing path suffixes resolve lexically,
    /// so not-yet-created roots still compare correctly.
    static func isWithin(child: String, orEqualTo ancestor: String) -> Bool {
        let c = canonicalized(child)
        let a = canonicalized(ancestor)
        return c == a || c.hasPrefix(a + "/")
    }

    static func canonicalized(_ path: String) -> String {
        ((path as NSString).standardizingPath as NSString).resolvingSymlinksInPath
    }

    static func standardized(_ path: String) -> String {
        (path as NSString).standardizingPath
    }

    static func uniquePath(inFolder folder: String, base: String, ext: String?) -> String {
        let fm = FileManager.default
        func compose(_ stem: String) -> String {
            let name = (ext?.isEmpty == false) ? "\(stem).\(ext!)" : stem
            return (folder as NSString).appendingPathComponent(name)
        }
        var candidate = compose(base)
        var counter = 2
        // fileExists follows symlinks, so a project-controlled BROKEN link at
        // the candidate name would read as free; lstat (isSymlink) treats any
        // link as occupied so creation never lands on one.
        while fm.fileExists(atPath: candidate) || isSymlink(candidate) {
            candidate = compose("\(base)-\(counter)")
            counter += 1
        }
        return candidate
    }

    /// First 6 alphanumerics from the tail of an id (session), for a short,
    /// stable, collision-resistant folder suffix.
    static func shortSuffix(of id: String) -> String {
        let alnum = id.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        return String(String.UnicodeScalarView(alnum.suffix(6))).lowercased()
    }

    /// Deterministic 6-hex FNV-1a hash of `value`, so the same cwd always maps to
    /// the same workspace folder suffix across app restarts.
    static func shortHash(of value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        let hex = String(hash, radix: 16)
        return String(hex.suffix(6))
    }

    static func writeJSON<T: Encodable>(_ value: T, toPath path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try data.write(to: URL(fileURLWithPath: path), options: [.atomic])
    }

    static func readJSON<T: Decodable>(fromPath path: String) throws -> T {
        guard let data = try markerDataReader.readIfPresent(atPath: path) else {
            throw POSIXError(.ENOENT)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
