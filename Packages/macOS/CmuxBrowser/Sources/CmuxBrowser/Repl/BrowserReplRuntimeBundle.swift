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

    public init(replScripts: [Script], agentScripts: [Script], directory: URL? = nil) {
        self.replScripts = replScripts
        self.agentScripts = agentScripts
        self.directory = directory
    }

    /// Name of the load-order manifest inside the resource directory.
    public static let manifestName = "manifest.json"

    /// Loads the bundle from `directory` in the order `manifest.json` gives:
    /// `{ "repl": [...], "agent": [...] }`, paths relative to `directory`.
    /// - Throws: ``BrowserReplRuntimeBundleError`` when the manifest is
    ///   missing or malformed, or when it names a file that cannot be read.
    public static func load(from directory: URL) throws -> BrowserReplRuntimeBundle {
        let manifestURL = directory.appendingPathComponent(manifestName)
        guard let data = try? Data(contentsOf: manifestURL) else {
            throw BrowserReplRuntimeBundleError.manifestMissing(path: manifestURL.path)
        }
        guard let manifest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let replOrder = manifest["repl"] as? [String],
              let agentOrder = manifest["agent"] as? [String],
              !replOrder.isEmpty, !agentOrder.isEmpty else {
            throw BrowserReplRuntimeBundleError.manifestInvalid(path: manifestURL.path)
        }
        let probe = BrowserReplRuntimeBundle(replScripts: [], agentScripts: [], directory: directory)
        func read(_ names: [String]) throws -> [Script] {
            try names.map { name in
                guard let source = probe.readResource(name) else {
                    throw BrowserReplRuntimeBundleError.scriptMissing(
                        name: name,
                        path: directory.appendingPathComponent(name).path
                    )
                }
                return Script(name: name, source: source)
            }
        }
        return BrowserReplRuntimeBundle(
            replScripts: try read(replOrder),
            agentScripts: try read(agentOrder),
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

/// Why the REPL runtime could not be loaded from its resource directory.
public enum BrowserReplRuntimeBundleError: Error, Equatable, CustomStringConvertible {
    /// `manifest.json` does not exist or cannot be read.
    case manifestMissing(path: String)
    /// `manifest.json` is not `{ "repl": [...], "agent": [...] }` with both lists non-empty.
    case manifestInvalid(path: String)
    /// The manifest names a file that does not exist inside the directory.
    case scriptMissing(name: String, path: String)

    public var description: String {
        switch self {
        case .manifestMissing(let path):
            return "browser REPL runtime manifest is missing: \(path)"
        case .manifestInvalid(let path):
            return "browser REPL runtime manifest is invalid (expected {\"repl\": [...], \"agent\": [...]}): \(path)"
        case .scriptMissing(let name, let path):
            return "browser REPL runtime file \(name) listed in manifest.json is missing: \(path)"
        }
    }
}
