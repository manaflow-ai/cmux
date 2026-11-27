public import Foundation

/// An unpacked web update: the repository layout of `build-web-bundles.sh --out-root`
/// (plans/cmux-next/web-ota.md). ``outputDigest()`` is web-bundle-key.py's `--outputs`
/// digest (Rust's `web_updates.tree_digest`, cmux-app-ffi src/updater/web_updates.rs), the `outputs` a signed pointer names, so a tree on disk is checked against the
/// signature again at every launch, not only when it was downloaded.
nonisolated public struct WebUpdateTree: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// Each output by name, so a change to the list never moves a caller onto another output.
    public static let agentPaneOutput = "Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/Resources/agent-pane"
    public static let pagesOutput = "Packages/macOS/CmuxNext/Sources/CmuxNextPages/Resources/pages"
    public static let agentActivityOutput = "Packages/macOS/CmuxNext/Sources/CmuxNextAgentActivity/Resources/agent-activity"
    public static let webviewsAppOutput = "Resources/markdown-viewer/webviews-app"
    public static let inspectorOutput = "Native/OptChat/optchat-chief/inspector/index.html"

    /// web-bundle-key.py OUTPUTS, in its order (WebUpdateTreeTests reads the script to keep them equal).
    public static let outputs = [agentPaneOutput, pagesOutput, agentActivityOutput, webviewsAppOutput, inspectorOutput]

    /// The native interface the tree's bundles need (`pages/web-abi.json`), nil when missing.
    public var abi: Int? { Self.abi(inPages: root.appending(path: Self.pagesOutput, directoryHint: .isDirectory)) }

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
        let reply = UpdaterRust.call("web_updates.tree_digest", ["root": root.path]) as? [String: Any]
        if let digest = reply?["digest"] as? String { return digest }
        throw WebUpdateRefusal(rust: reply?["refusal"])
    }
}
