import CmuxNextCompat
import CryptoKit
import Darwin
public import Foundation

/// What a kept bundle's full signature check covered, sealed: a digest over every item in the
/// bundle (its path, type, mode, size, inode and change time; a symlink's target). A rollback trusts
/// a kept build's recorded team, without checking every file's signature again at the click, only
/// while the bundle's seal is the one taken around that full check.
///
/// The change time is the kernel's: any write to a file, a rename or replacement into the bundle,
/// a chmod or a touch moves it (or the inode), and no process sets it back. A file added or removed
/// changes the list. So a bundle whose seal matches has every byte the full check read, without the
/// check having to read them again (seconds for a Chromium bundle; the walk is a stat per file).
/// Review of cmux#41013: a fingerprint of only the signature files and the executable let a changed
/// resource (bundled JavaScript) through a check that skipped resources.
nonisolated public struct KeptSeal: Codable, Equatable, Sendable {
    /// SHA-256 of the walk, hex.
    public var digest: String
    /// How many items it covered (a quick, readable sanity check in `kept.json`).
    public var items: Int

    /// The seal of `bundle` now; nil when it cannot be read.
    public init?(bundle: URL) {
        let rootURL = bundle.standardizedFileURL.resolvingSymlinksInPath()
        let root = rootURL.path
        guard let walker = FileManager.checked.enumerator(at: rootURL, includingPropertiesForKeys: nil) else { return nil }
        var paths: [String] = [""]
        // The enumerator names each item under `rootURL` as given (it does not follow symlinks).
        while let next = walker.nextObject() as? URL {
            let path = next.path
            guard path.hasPrefix(root + "/") else { return nil }
            paths.append(String(path.dropFirst(root.count + 1)))
        }
        paths.sort()
        var hash = SHA256()
        for path in paths {
            let full = path.isEmpty ? root : root + "/" + path
            var info = stat()
            guard lstat(full, &info) == 0 else { return nil }
            var line = "\(path)\u{0}\(info.st_mode)\u{0}\(info.st_size)\u{0}\(info.st_ino)\u{0}"
                + "\(info.st_ctimespec.tv_sec).\(info.st_ctimespec.tv_nsec)"
            if info.st_mode & S_IFMT == S_IFLNK {
                line += "\u{0}" + ((try? FileManager.checked.destinationOfSymbolicLink(atPath: full)) ?? "?")
            }
            hash.update(data: Data((line + "\n").utf8))
        }
        digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        items = paths.count
    }

    /// The team `fullCheck` finds for `bundle`, with the seal taken around it: both nil when the
    /// check fails, or when the bundle changed while it ran (the seals before and after differ).
    static func verified(_ bundle: URL, fullCheck: (URL) -> String?) -> (team: String, seal: KeptSeal)? {
        guard let before = KeptSeal(bundle: bundle), let team = fullCheck(bundle),
              let after = KeptSeal(bundle: bundle), before == after else { return nil }
        return (team, after)
    }
}
