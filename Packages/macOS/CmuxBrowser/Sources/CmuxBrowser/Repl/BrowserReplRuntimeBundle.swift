public import Foundation

/// The JavaScript that makes up the REPL runtime and the page agent, read
/// from the app's `browser-repl` resource directory.
public struct BrowserReplRuntimeBundle: Sendable {
    /// One loaded script.
    public struct Script: Sendable, Equatable {
        /// Path relative to the resource directory, used as the source URL.
        public let name: String
        public let source: String
    }

    /// Scripts evaluated, in order, in each REPL `JSContext`.
    public let replScripts: [Script]
    /// Scripts installed, in order, in every frame's agent content world.
    public let agentScripts: [Script]
    /// The resource directory, for `readResource`.
    public let directory: URL?

    static let defaultReplOrder = ["runtime-core.js", "dialect-aside.js", "dialect-chatgpt.js", "repl-host.js"]
    static let defaultAgentOrder = ["vendor/playwright-injected.js", "page-agent.js"]

    public init(replScripts: [Script], agentScripts: [Script], directory: URL? = nil) {
        self.replScripts = replScripts
        self.agentScripts = agentScripts
        self.directory = directory
    }

    /// Loads the bundle from `directory`, honoring `manifest.json`
    /// (`{ "repl": [...], "agent": [...] }`) when present. Missing files are skipped.
    public static func load(from directory: URL) -> BrowserReplRuntimeBundle {
        var replOrder = defaultReplOrder
        var agentOrder = defaultAgentOrder
        if let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")),
           let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let repl = manifest["repl"] as? [String] { replOrder = repl }
            if let agent = manifest["agent"] as? [String] { agentOrder = agent }
        }
        func read(_ names: [String]) -> [Script] {
            names.compactMap { name in
                guard let source = try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8) else {
                    return nil
                }
                return Script(name: name, source: source)
            }
        }
        return BrowserReplRuntimeBundle(
            replScripts: read(replOrder),
            agentScripts: read(agentOrder),
            directory: directory
        )
    }

    /// Reads a text resource inside the bundle directory, refusing paths
    /// that leave it.
    public func readResource(_ relativePath: String) -> String? {
        guard let directory else { return nil }
        let base = directory.standardizedFileURL.path
        let target = directory.appendingPathComponent(relativePath).standardizedFileURL.path
        guard target.hasPrefix(base + "/") else { return nil }
        return try? String(contentsOfFile: target, encoding: .utf8)
    }

    /// Marks a frame's agent world as installed; evaluated after the agent scripts.
    public static let agentInstalledMarkerSource = "globalThis.__cmuxAgentInstalled = true;"

    /// Evaluates to `true` in a frame whose agent world is installed.
    public static let agentInstalledProbeSource = "globalThis.__cmuxAgentInstalled === true"
}
