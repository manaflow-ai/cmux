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

    static let defaultReplOrder = [
        "vendor/acorn.js",
        "vendor/playwright-locator-utils.js",
        "runtime-core.js",
        "dialect-aside.js",
        "dialect-chatgpt.js",
        "repl-host.js",
    ]
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

    /// Key under which the page agent stores itself on `globalThis`.
    public static let agentGlobalKeyExpression = #"Symbol.for("cmux.browserRepl.agent")"#

    /// Evaluates to `true` in a frame whose agent world is installed.
    public static let agentInstalledProbeSource = "globalThis[\(agentGlobalKeyExpression)] !== undefined"

    /// One script that installs the agent in a frame, following the recipe in
    /// `page-agent.js`: Playwright's injected-script bundle runs with a local
    /// `module` binding, and its factory is handed to the page agent. The
    /// agent itself refuses to install twice, so re-running is harmless.
    public var agentInstallSource: String? {
        guard !agentScripts.isEmpty else { return nil }
        var parts = ["(() => {", "const module = { exports: {} };"]
        var rest = agentScripts[...]
        if let first = agentScripts.first, first.name.contains("playwright-injected") {
            parts.append(first.source)
            parts.append("const __cmuxInjectedScriptFactory = module.exports.InjectedScript;")
            rest = agentScripts.dropFirst()
        }
        for script in rest {
            parts.append(";")
            parts.append(script.source)
        }
        parts.append("})();")
        return parts.joined(separator: "\n")
    }
}
