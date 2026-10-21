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

    /// The native interface the tree's bundles need (`pages/web-abi.json`), nil when missing.
    public var abi: Int? { Self.abi(inPages: root.appending(path: Self.outputs[1], directoryHint: .isDirectory)) }

    /// The `abi` of the `web-abi.json` in a pages folder (the bundled one or an update's).
    public static func abi(inPages pages: URL) -> Int? {
        nonisolated struct File: Decodable { var abi: Int }
        guard let data = try? Data(contentsOf: pages.appending(path: "web-abi.json")) else { return nil }
        return (try? JSONDecoder().decode(File.self, from: data))?.abi
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
