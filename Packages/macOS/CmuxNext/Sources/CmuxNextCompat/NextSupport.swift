public import Foundation

/// NEXT's own folders in a `~/Library/Application Support`, beside classic cmux's `cmux`
/// (cmuxterm-hq goals/next-store-out-of-classic.md): `cmux-next` (``folder``) and, in it, each
/// bundle's own folder (``bundleFolder(bundleID:)``). Rust's `cmux_cloud_environment::bundle_folder`
/// names the same folder for the CLI.
public struct NextSupport: Sendable {
    /// The `Application Support` folder these are in.
    public let applicationSupport: URL

    public init(applicationSupport: URL = NextSupport.applicationSupportDirectory()) {
        self.applicationSupport = applicationSupport
    }

    /// `<applicationSupport>/cmux-next`.
    public var folder: URL { applicationSupport.appendingPathComponent("cmux-next", isDirectory: true) }

    /// `<applicationSupport>/cmux-next/<bundle id>`: the bundle's Cloud state (`cloud-next`,
    /// `cloud-environment.json`, `client-config`), SSH link state (`ssh-next`) and namespaced sign-in
    /// stores. `cmux` outside any bundle.
    public func bundleFolder(bundleID: String?) -> URL {
        folder.appendingPathComponent(bundleID ?? "cmux", isDirectory: true)
    }

    /// Where builds before kept ``bundleFolder(bundleID:)``'s items: classic's `cmux/<bundle id>`,
    /// which classic cmux of the same bundle id (NIGHTLY's `com.cmuxterm.app.nightly`) also uses.
    public func classicBundleFolder(bundleID: String?) -> URL {
        applicationSupport.appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent(bundleID ?? "cmux", isDirectory: true)
    }

    /// `<applicationSupport>/cmux-next/cmux-cua/runtime/<scope>`: the Computer Use helper's runtime
    /// folder for a bundle (its `agent-token` and `state`), named by ``computerUseScope(_:)``.
    public func computerUseRuntime(bundleID: String) -> URL {
        folder.appendingPathComponent("cmux-cua/runtime/\(Self.computerUseScope(bundleID))", isDirectory: true)
    }

    /// Where builds before kept ``computerUseRuntime(bundleID:)``: classic's `cmux/cmux-cua/runtime/<scope>`.
    public func classicComputerUseRuntime(bundleID: String) -> URL {
        applicationSupport.appendingPathComponent("cmux/cmux-cua/runtime/\(Self.computerUseScope(bundleID))", isDirectory: true)
    }

    /// A stable 16-hex scope for a bundle id (FNV-1a): the name of the bundle's Computer Use items.
    public static func computerUseScope(_ bundleID: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in bundleID.utf8 { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
        return String(format: "%016llx", hash)
    }

    /// The name a path in a bundle folder is known by wherever it is hashed into a name that should
    /// outlive the move (a link socket): its path in classic's `cmux` from before the move. Every
    /// other path is its own name.
    public static func pathIdentity(_ path: String) -> String {
        var parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let at = parts.indices.dropLast().first(where: { parts[$0] == "Application Support" && parts[$0 + 1] == "cmux-next" })
        else { return path }
        parts[at + 1] = "cmux"
        return parts.joined(separator: "/")
    }

    /// The user's `~/Library/Application Support`.
    public static func applicationSupportDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
    }
}
