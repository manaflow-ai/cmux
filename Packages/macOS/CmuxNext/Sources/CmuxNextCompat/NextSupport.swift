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

    /// The user's `~/Library/Application Support`; `<state root>/Library/Application Support` under a
    /// state root (``stateRootKey``).
    public static func applicationSupportDirectory() -> URL {
        if let root = currentStateRoot { return root.appendingPathComponent("Library/Application Support", isDirectory: true) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
    }

    /// The user's `~/Library/Caches`, beside ``applicationSupportDirectory()``: `<state root>/Library/Caches` under a
    /// state root (``stateRootKey``).
    public static func cachesDirectory() -> URL {
        applicationSupportDirectory().deletingLastPathComponent().appendingPathComponent("Caches", isDirectory: true)
    }

    // MARK: - State root

    /// The launch variable naming a state root, an absolute folder that stands for the home of everything a
    /// launch keeps: its Application Support and Caches are the root's `Library/Application Support` and
    /// `Library/Caches`, and every sign-in it keeps in the Keychain carries ``runSegment(stateRoot:)``, so a
    /// fresh folder is a fresh person. Rust's `cmux_cloud_environment::STATE_ROOT_ENV` reads the same
    /// variable for the CLI and the daemon. Unset, blank or relative: no state root, nothing changes.
    public static let stateRootKey = "CMUX_NEXT_STATE_ROOT"

    /// The state root `environment` names: an absolute path, trailing slashes dropped; nil for an unset,
    /// blank or relative value (Rust's `cmux_cloud_environment::state_root`).
    public static func stateRoot(environment: [String: String]) -> URL? {
        guard let value = environment[stateRootKey]?.trimmingCharacters(in: .whitespacesAndNewlines), value.hasPrefix("/") else {
            return nil
        }
        var path = Substring(value)
        while path.count > 1, path.hasSuffix("/") { path = path.dropLast() }
        return URL(fileURLWithPath: String(path), isDirectory: true)
    }

    /// This process's state root, read once at first use.
    public static let currentStateRoot: URL? = stateRoot(environment: ProcessInfo.processInfo.environment)

    /// `run-` and the FNV-1a 64 hash of the root's path as 16 hex digits: the suffix of every Keychain service and
    /// sign-in namespace a launch on `stateRoot` keeps (Rust's `cmux_cloud_environment::run_segment` makes the same).
    public static func runSegment(stateRoot: URL) -> String {
        "run-\(computerUseScope(stateRoot.path))"
    }

    /// This process's ``runSegment(stateRoot:)``; nil without a state root.
    public static let currentRunSegment: String? = currentStateRoot.map { runSegment(stateRoot: $0) }
}
