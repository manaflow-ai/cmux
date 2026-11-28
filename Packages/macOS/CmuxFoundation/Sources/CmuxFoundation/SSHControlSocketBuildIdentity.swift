public import Foundation

/// The cmux build whose ssh control sockets a process opens, and how that build's sockets are named.
///
/// The release app, a nightly and tagged development builds can run side by side and connect to the
/// same hosts. A host that allows one session per connection (`MaxSessions 1`) lets one of them use a
/// master at a time, and every other build's command on it is refused ("Session open refused by
/// peer"). So each build gets masters of its own. The release app keeps the names it has always had,
/// so a live master survives the upgrade that introduced the per-build names.
///
/// Mirror sockets and `cmux ssh` sockets separate builds in two ways. A mirror socket's file name ends
/// in a digest, and other builds mix their identifier into it. A `cmux ssh` socket keeps OpenSSH's
/// `%C` name, so other builds get a directory of their own. The app and the CLI build this value from
/// their own bundle and hand it to the code that names sockets.
public struct SSHControlSocketBuildIdentity: Sendable, Equatable {
    /// The release app's bundle identifier.
    public static let releaseBundleIdentifier = "com.cmuxterm.app"

    /// `nil` for the release app, or when there is no identifier, and the bundle identifier for any
    /// other build.
    public let namespace: String?

    public init(bundleIdentifier: String?) {
        if let bundleIdentifier, !bundleIdentifier.isEmpty,
           bundleIdentifier != Self.releaseBundleIdentifier {
            namespace = bundleIdentifier
        } else {
            namespace = nil
        }
    }

    /// The identity of a process that may have no bundle identifier of its own.
    ///
    /// The bundled CLI has none, since `Bundle.main` has no identifier for a command-line tool, so it
    /// takes the identifier of the `.app` its executable sits in, following symlinks so a linked `cmux`
    /// on PATH resolves to the app it came from. The app and its CLI then name the same sockets.
    public init(bundleIdentifier: String?, executableURL: URL?) {
        self.init(bundleIdentifier: bundleIdentifier ?? executableURL.flatMap(enclosingAppBundleIdentifier))
    }

    /// The digest at the end of a mirror socket's file name: `connectionHash` itself for the release
    /// app, mixed with the namespace for any other build. Both are 16 hex characters, so the path
    /// budget does not change.
    public func socketKey(connectionHash: String) -> String {
        guard let namespace else { return connectionHash }
        return String(format: "%016llx", fnv1a64("\(connectionHash)\u{1f}\(namespace)"))
    }

    /// The directory under `~/.cmux/ssh` that holds this build's `cmux ssh` sockets, or `nil` for the
    /// release app, which uses `~/.cmux/ssh` itself.
    ///
    /// Eight lowercase hex characters, so a long tag cannot push the socket path past the AF_UNIX
    /// limit: the nested directory costs nine bytes of a 103-byte path that already holds a
    /// 40-character socket name and OpenSSH's 17-byte bind suffix.
    public var directoryName: String? {
        namespace.map { String(format: "%08llx", fnv1a64($0) & 0xffff_ffff) }
    }
}

private func enclosingAppBundleIdentifier(_ executableURL: URL) -> String? {
    var url = executableURL.resolvingSymlinksInPath()
    while url.pathComponents.count > 1 {
        url.deleteLastPathComponent()
        if url.pathExtension == "app" {
            return Bundle(url: url)?.bundleIdentifier
        }
    }
    return nil
}

private func fnv1a64(_ string: String) -> UInt64 {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in string.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 0x0000_0100_0000_01b3
    }
    return hash
}
