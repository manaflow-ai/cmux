internal import Foundation

/// Which cmux build an ssh control socket belongs to, and how that build's sockets are named.
///
/// The release app, a nightly and tagged development builds can run side by side and connect to the
/// same hosts. A host that allows one session per connection (`MaxSessions 1`) lets one of them use a
/// master at a time, and every other build's command on it is refused ("Session open refused by
/// peer"). So each build gets masters of its own. The release app keeps the names it has always had,
/// so a live master survives the upgrade that introduced the per-build names.
///
/// Mirror sockets and `cmux ssh` sockets separate builds in two ways. A mirror socket's file name ends
/// in a digest, and other builds mix their identifier into it. A `cmux ssh` socket keeps OpenSSH's
/// `%C` name, so other builds get a directory of their own. Callers look up their own bundle
/// identifier and pass it in.
public enum SSHControlSocketBuildIdentity {
    /// The release app's bundle identifier.
    public static let releaseBundleIdentifier = "com.cmuxterm.app"

    /// The namespace a build's sockets use: `nil` for the release app, or when there is no
    /// identifier, and the bundle identifier for any other build.
    public static func namespace(bundleIdentifier: String?) -> String? {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty,
              bundleIdentifier != releaseBundleIdentifier else { return nil }
        return bundleIdentifier
    }

    /// The digest at the end of a mirror socket's file name: `connectionHash` itself for the release
    /// app, mixed with the namespace for any other build. Both are 16 hex characters, so the path
    /// budget does not change.
    public static func socketKey(connectionHash: String, namespace: String?) -> String {
        guard let namespace else { return connectionHash }
        return String(format: "%016llx", fnv1a64("\(connectionHash)\u{1f}\(namespace)"))
    }

    /// The directory under `~/.cmux/ssh` that holds a build's `cmux ssh` sockets.
    ///
    /// Eight hex characters, so a long tag cannot push the socket path past the AF_UNIX limit: the
    /// nested directory costs nine bytes of a 103-byte path that already holds a 40-character socket
    /// name and OpenSSH's 17-byte bind suffix.
    public static func directoryName(for namespace: String) -> String {
        String(format: "%08llx", fnv1a64(namespace) & 0xffff_ffff)
    }

    /// Whether `name` is a directory name ``directoryName(for:)`` produces.
    public static func isNamespaceDirectoryName(_ name: String) -> Bool {
        name.utf8.count == 8 && name.utf8.allSatisfy { byte in
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
        }
    }

    private static func fnv1a64(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }
}
