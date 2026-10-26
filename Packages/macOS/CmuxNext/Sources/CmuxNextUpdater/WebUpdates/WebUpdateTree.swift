import CmuxNextCompat
import CryptoKit
public import Foundation

/// An unpacked web update: the repository layout of `build-web-bundles.sh --out-root`
/// (plans/cmux-next/web-ota.md). ``outputDigest(root:)`` is web-bundle-key.py's `--outputs`
/// digest, the `outputs` a signed pointer names, so a tree on disk is checked against the
/// signature again at every launch, not only when it was downloaded.
nonisolated public struct WebUpdateTree: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// web-bundle-key.py OUTPUTS, in its order (WebUpdateTreeTests reads the script to keep them equal).
    public static let outputs = [
        "Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/Resources/agent-pane",
        "Packages/macOS/CmuxNext/Sources/CmuxNextPages/Resources/pages",
        "Packages/macOS/CmuxNext/Sources/CmuxNextAgentActivity/Resources/agent-activity",
        "Packages/macOS/CmuxNext/Sources/CmuxNextPalette/Resources/palette-ranker.js",
        "Resources/markdown-viewer/webviews-app",
        "Native/OptChat/optchat-chief/inspector/index.html",
    ]
    static let ignoredNames: Set<String> = [".DS_Store"]

    /// Where the files of `cmux-page://cmux.shared/` sit in the tree (the pages' `_shared`, web-bundle-key.py
    /// SHARED_ROOT): every web tree imports React from there, so a page and the shared files it names come
    /// from one tree.
    public static let sharedRoot = outputs[1] + "/_shared"
    static let sharedPrefix = Data("cmux-page://cmux.shared/".utf8)
    /// The files a shared name is read from, and the types a name counts for (web-bundle-key.py).
    static let sharedScanned: Set<String> = ["html", "js", "mjs", "css"]
    static let sharedTypes = [".js", ".css"]

    /// The native interface the tree's bundles need (`pages/web-abi.json`), nil when missing.
    public var abi: Int? { Self.abi(inPages: root.appending(path: Self.outputs[1], directoryHint: .isDirectory)) }

    /// The `abi` of the `web-abi.json` in a pages folder (the bundled one or an update's).
    public static func abi(inPages pages: URL) -> Int? {
        nonisolated struct File: Decodable { var abi: Int }
        guard let data = try? Data(contentsOf: pages.appending(path: "web-abi.json")) else { return nil }
        return (try? JSONDecoder().blockingDecode(File.self, from: data))?.abi
    }

    /// The `--outputs` digest of the tree. Throws for a link or any other non-regular file, which
    /// an archive never holds (web-bundle-archive.py refuses them). Blocking reads: call it off the
    /// main actor.
    public func outputDigest() throws(WebUpdateRefusal) -> String {
        var hash = SHA256()
        for top in Self.outputs {
            let base = root.appending(path: top)
            var files: [String] = []
            switch try Self.kind(of: base) {
            case .file: files = [top]
            case .directory: files = try Self.walk(base, relative: top)
            case .missing:
                hash.update(data: Data("missing \(top)\n".utf8))
                continue
            }
            if files.isEmpty { hash.update(data: Data("empty \(top)\n".utf8)) }
            for rel in files {
                guard let data = try? Data(contentsOf: root.appending(path: rel), options: .mappedIfSafe) else {
                    throw .integrity("unreadable \(rel)")
                }
                hash.update(data: Data("\(rel)\u{0}\(Self.hex(SHA256.hash(data: data)))\n".utf8))
            }
        }
        return Self.hex(hash.finalize())
    }

    /// Each `cmux-page://cmux.shared/<file>` a bundle of the tree names that the tree's own ``sharedRoot``
    /// does not hold (web-bundle-key.py `--shared`), sorted; empty for a whole tree. A page of a tree that
    /// names a file the tree lacks would not load its React. Throws for a link or an unreadable file, as
    /// ``outputDigest()``. Blocking reads: call it off the main actor.
    public func missingSharedFiles() throws(WebUpdateRefusal) -> [String] {
        let shared = root.appending(path: Self.sharedRoot, directoryHint: .isDirectory)
        var missing: Set<String> = []
        for rel in try outputFiles() where Self.sharedScanned.contains((rel as NSString).pathExtension) {
            guard let data = try? Data(blockingContentsOf: root.appending(path: rel), options: .mappedIfSafe) else {
                throw .integrity("unreadable \(rel)")
            }
            for name in Self.sharedNames(in: data) {
                if try !Self.holds(shared, name) { missing.insert(name) }
            }
        }
        return missing.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }

    /// Every file of the tree's outputs, relative to ``root``, in ``outputDigest()``'s order.
    func outputFiles() throws(WebUpdateRefusal) -> [String] {
        var files: [String] = []
        for top in Self.outputs {
            let base = root.appending(path: top)
            switch try Self.kind(of: base) {
            case .file: files.append(top)
            case .directory: files += try Self.walk(base, relative: top)
            case .missing: continue
            }
        }
        return files
    }

    /// The names after each `cmux-page://cmux.shared/` in `data`: the longest run of name bytes
    /// (`A-Z a-z 0-9 . _ / -`), kept when it ends in `.js` or `.css` (web-bundle-key.py SHARED_URL).
    static func sharedNames(in data: Data) -> Set<String> {
        var names: Set<String> = []
        var start = data.startIndex
        while let found = data.range(of: sharedPrefix, in: start..<data.endIndex) {
            var end = found.upperBound
            while end < data.endIndex, isNameByte(data[end]) { end += 1 }
            let name = String(decoding: data[found.upperBound..<end], as: UTF8.self)
            if sharedTypes.contains(where: { name.hasSuffix($0) }) { names.insert(name) }
            start = end
        }
        return names
    }

    static func isNameByte(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "0")...UInt8(ascii: "9"),
             UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "/"), UInt8(ascii: "-"):
            true
        default:
            false
        }
    }

    /// Whether `shared` holds the regular file `name`: never for a name with an empty, `.` or `..`
    /// component. Throws for a link, as ``outputDigest()``.
    static func holds(_ shared: URL, _ name: String) throws(WebUpdateRefusal) -> Bool {
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return false }
        return try kind(of: shared.appending(path: name)) == .file
    }

    enum Kind { case file, directory, missing }

    static func kind(of url: URL) throws(WebUpdateRefusal) -> Kind {
        guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey]) else {
            return .missing
        }
        if values.isSymbolicLink == true { throw .integrity("link \(url.lastPathComponent)") }
        if values.isDirectory == true { return .directory }
        if values.isRegularFile == true { return .file }
        throw .integrity("special file \(url.lastPathComponent)")
    }

    /// os.walk order: a folder's files by name, then each subfolder by name.
    static func walk(_ directory: URL, relative: String) throws(WebUpdateRefusal) -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            throw .integrity("unreadable \(relative)")
        }
        let sorted = names.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        var files: [String] = []
        var directories: [String] = []
        for name in sorted {
            switch try kind(of: directory.appending(path: name)) {
            case .file where !ignoredNames.contains(name): files.append("\(relative)/\(name)")
            case .directory: directories.append(name)
            case .file, .missing: break
            }
        }
        for name in directories {
            files += try walk(directory.appending(path: name, directoryHint: .isDirectory), relative: "\(relative)/\(name)")
        }
        return files
    }

    static func hex(_ digest: some Sequence<UInt8>) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
