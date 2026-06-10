import Foundation
import CMUXAgentLaunch
import CmuxFoundation
import CmuxSocketControl
import CoreFoundation
import CryptoKit
import Darwin
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
#if canImport(Security)
import Security
#endif
#if canImport(Sentry)
import Sentry
#endif


// MARK: - OpenCode plugin install
extension CMUXCLI {

    private static let openCodeSessionPluginMarker = "cmux-opencode-session-plugin-marker"
    private static let openCodeSessionPluginFilename = "cmux-session.js"
    private static let openCodeSessionPluginSource = #"""
// cmux-opencode-session-plugin-marker v1
// Bridges OpenCode session lifecycle events into cmux's restorable session store.
// Installed by `cmux hooks opencode install` or `cmux hooks setup`.
// DO NOT EDIT MANUALLY. cmux upgrades this file in place.

import { spawnSync } from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";

const CMUX_PLUGIN_INSTALLED_KEY = Symbol.for("cmux.session.restore.plugin.installed");

function firstString(...values) {
  for (const value of values) {
    if (typeof value === "string" && value.trim().length > 0) return value.trim();
  }
  return null;
}

function eventProperties(event) {
  return (event && typeof event === "object" && event.properties) || {};
}

function sessionIdFor(event) {
  const props = eventProperties(event);
  return firstString(
    props.info && props.info.id,
    props.sessionID,
    props.sessionId,
    props.session_id,
    props.session && props.session.id,
    event && event.sessionID,
    event && event.sessionId,
    event && event.id
  );
}

function cwdFor(ctx, event) {
  const props = eventProperties(event);
  return firstString(
    props.info && props.info.directory,
    props.cwd,
    props.directory,
    ctx && ctx.directory,
    process.cwd()
  );
}

function resolveExecutable(name) {
  const pathEnv = process.env.PATH || "";
  for (const dir of pathEnv.split(path.delimiter)) {
    if (!dir) continue;
    const candidate = path.join(dir, name);
    try {
      fs.accessSync(candidate, fs.constants.X_OK);
      return candidate;
    } catch (_) {}
  }
  return name;
}

function looksLikeOpenCodeScript(value) {
  if (!value) return false;
  const lower = String(value).toLowerCase();
  return lower.includes("opencode") || lower.includes("open-code");
}

function isOpenCodeInternalWorkerArg(value) {
  if (!value) return false;
  const normalized = String(value).replaceAll("\\", "/");
  return normalized.includes("/$bunfs/") && normalized.includes("/src/cli/cmd/tui/worker.js");
}

function withoutOpenCodeInternalWorkerArgs(argv) {
  const result = [];
  for (let i = 0; i < argv.length; i += 1) {
    const value = argv[i];
    if (i > 0 && isOpenCodeInternalWorkerArg(value)) continue;
    result.push(value);
  }
  return result.length > 0 ? result : [resolveExecutable("opencode")];
}

function normalizedLaunchArgv() {
  const raw = Array.isArray(process.argv) ? process.argv.map((value) => String(value)) : [];
  if (raw.length === 0) return [resolveExecutable("opencode")];

  const firstBase = path.basename(raw[0]).toLowerCase();
  if (looksLikeOpenCodeScript(firstBase)) return withoutOpenCodeInternalWorkerArgs(raw);

  let tail = raw.slice(1);
  if (tail.length > 0 && looksLikeOpenCodeScript(tail[0])) {
    tail = tail.slice(1);
  }
  return withoutOpenCodeInternalWorkerArgs([resolveExecutable("opencode"), ...tail]);
}

function base64NulSeparated(values) {
  const bytes = [];
  for (const value of values) {
    bytes.push(Buffer.from(String(value), "utf8"));
    bytes.push(Buffer.from([0]));
  }
  return Buffer.concat(bytes).toString("base64");
}

function hookEnvironment(cwd) {
  const env = { ...process.env };
  delete env.AMP_API_KEY;
  if (!env.CMUX_AGENT_LAUNCH_ARGV_B64) {
    const argv = normalizedLaunchArgv();
    env.CMUX_AGENT_LAUNCH_KIND = "opencode";
    env.CMUX_AGENT_LAUNCH_EXECUTABLE = argv[0] || resolveExecutable("opencode");
    env.CMUX_AGENT_LAUNCH_ARGV_B64 = base64NulSeparated(argv);
    env.CMUX_AGENT_LAUNCH_CWD = cwd || process.cwd();
  }
  return env;
}

function sendHook(subcommand, ctx, event, extra = {}) {
  if (process.env.CMUX_OPENCODE_HOOKS_DISABLED === "1") return;
  if (!process.env.CMUX_SURFACE_ID) return;

  const sessionId = sessionIdFor(event);
  if (!sessionId) return;

  const cwd = cwdFor(ctx, event);
  const payload = {
    session_id: sessionId,
    cwd,
    event: event && event.type,
    hook_event_name: event && event.type,
    ...extra,
  };
  const cmux = process.env.CMUX_OPENCODE_CMUX_BIN || "cmux";
  try {
    spawnSync(cmux, ["hooks", "opencode", subcommand], {
      input: JSON.stringify(payload),
      encoding: "utf8",
      env: hookEnvironment(cwd),
      stdio: ["pipe", "ignore", "ignore"],
      timeout: 5000,
    });
  } catch (_) {}
}

const CMUXSessionRestore = async (ctx) => {
  if (globalThis[CMUX_PLUGIN_INSTALLED_KEY]) return {};
  globalThis[CMUX_PLUGIN_INSTALLED_KEY] = true;
  return {
    event: async ({ event }) => {
      const props = eventProperties(event);
      switch (event && event.type) {
        case "session.created":
          sendHook("session-start", ctx, event);
          break;
        case "session.updated":
          if (props.info && props.info.time && props.info.time.archived) {
            sendHook("session-end", ctx, event);
          } else {
            sendHook("session-start", ctx, event);
          }
          break;
        case "session.status":
          if (props.status && props.status.type === "idle") {
            sendHook("stop", ctx, event);
          }
          break;
        case "session.idle":
          sendHook("stop", ctx, event);
          break;
        case "session.deleted":
          sendHook("session-end", ctx, event);
          break;
        default:
          break;
      }
    },
  };
};

export { CMUXSessionRestore };
export default CMUXSessionRestore;
"""#

    private func openCodeSessionPluginURL(for def: AgentHookDef) -> URL {
        URL(fileURLWithPath: def.resolvedConfigDir(), isDirectory: true)
            .appendingPathComponent("plugins", isDirectory: true)
            .appendingPathComponent(Self.openCodeSessionPluginFilename, isDirectory: false)
    }

    func writeOpenCodeSessionPlugin(in configDir: URL) throws {
        let pluginURL = configDir
            .appendingPathComponent("plugins", isDirectory: true)
            .appendingPathComponent(Self.openCodeSessionPluginFilename, isDirectory: false)
        let fm = FileManager.default
        try fm.createDirectory(at: pluginURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.openCodeSessionPluginSource.write(to: pluginURL, atomically: true, encoding: .utf8)
    }

    static func openCodePluginListContains(
        _ plugins: [Any],
        spec: String,
        allowVersionSuffix: Bool = false
    ) -> Bool {
        plugins.contains { entry in
            let value: String?
            if let string = entry as? String {
                value = string
            } else if let tuple = entry as? [Any], let string = tuple.first as? String {
                value = string
            } else {
                value = nil
            }
            guard let value else { return false }
            if value == spec { return true }
            if allowVersionSuffix, value.hasPrefix("\(spec)@") { return true }
            if spec == Self.openCodeSessionPluginConfigSpec {
                return value == "./plugins/\(Self.openCodeSessionPluginFilename)"
                    || value.hasSuffix("/plugins/\(Self.openCodeSessionPluginFilename)")
                    || value.hasSuffix("/\(Self.openCodeSessionPluginFilename)")
            }
            return false
        }
    }

    private static func openCodePluginEntryName(_ entry: Any) -> String? {
        if let string = entry as? String {
            return string
        }
        if let tuple = entry as? [Any], let string = tuple.first as? String {
            return string
        }
        return nil
    }

    private static func openCodePluginSpecIsPackage(_ value: String, packageName: String) -> Bool {
        value == packageName || value.hasPrefix("\(packageName)@")
    }

    private static func openCodePluginSpecIsPinnedPackage(_ value: String, packageName: String) -> Bool {
        value.hasPrefix("\(packageName)@")
    }

    private static func openCodePluginEntryReplacingPackage(
        _ entry: Any,
        packageName: String,
        replacementPackageName: String
    ) -> Any {
        guard let name = openCodePluginEntryName(entry),
              openCodePluginSpecIsPackage(name, packageName: packageName)
        else {
            return entry
        }

        let replacementName = "\(replacementPackageName)\(name.dropFirst(packageName.count))"
        if entry is String {
            return replacementName
        }
        if var tuple = entry as? [Any] {
            tuple[0] = replacementName
            return tuple
        }
        return entry
    }

    private static func openCodePluginEntryIsOMOPackage(_ entry: Any) -> Bool {
        guard let name = openCodePluginEntryName(entry) else { return false }
        return openCodePluginSpecIsPackage(name, packageName: omoPluginName)
            || openCodePluginSpecIsPackage(name, packageName: legacyOmoPluginName)
    }

    private static func preferredOMOPluginEntry(from plugins: [Any]) -> Any? {
        var currentPinnedEntry: Any?
        var currentEntry: Any?
        var legacyEntry: Any?

        for entry in plugins {
            guard let name = openCodePluginEntryName(entry) else { continue }
            if openCodePluginSpecIsPackage(name, packageName: omoPluginName) {
                if openCodePluginSpecIsPinnedPackage(name, packageName: omoPluginName) {
                    if currentPinnedEntry == nil {
                        currentPinnedEntry = entry
                    }
                } else if currentEntry == nil {
                    currentEntry = entry
                }
                continue
            }

            if legacyEntry == nil,
               openCodePluginSpecIsPackage(name, packageName: legacyOmoPluginName) {
                legacyEntry = openCodePluginEntryReplacingPackage(
                    entry,
                    packageName: legacyOmoPluginName,
                    replacementPackageName: omoPluginName
                )
            }
        }

        return currentPinnedEntry ?? currentEntry ?? legacyEntry
    }

    static func openCodePluginListNormalizingOMOPlugin(_ plugins: [Any]) -> [Any] {
        guard let preferredEntry = preferredOMOPluginEntry(from: plugins) else {
            return plugins
        }

        var insertedOMOPlugin = false
        var normalized: [Any] = []
        for entry in plugins {
            if openCodePluginEntryIsOMOPackage(entry) {
                if !insertedOMOPlugin {
                    normalized.append(preferredEntry)
                    insertedOMOPlugin = true
                }
            } else {
                normalized.append(entry)
            }
        }
        return normalized
    }

    static func openCodePluginListRemovingSessionPlugin(_ plugins: [Any]) -> [Any] {
        plugins.filter { entry in
            guard let value = (entry as? String) ?? ((entry as? [Any])?.first as? String) else {
                return true
            }
            return value != Self.openCodeSessionPluginConfigSpec
                && value != "cmux-session"
                && value != "./plugins/\(Self.openCodeSessionPluginFilename)"
                && !value.hasSuffix("/plugins/\(Self.openCodeSessionPluginFilename)")
                && !value.hasSuffix("/\(Self.openCodeSessionPluginFilename)")
        }
    }

    private func updateOpenCodePluginRegistration(configDir: URL, shouldInstall: Bool) throws -> Bool {
        let configURL = configDir.appendingPathComponent("opencode.json", isDirectory: false); let existingData = try? Data(contentsOf: configURL)
        var config: [String: Any]
        if let data = existingData {
            guard let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CLIError(message: "Failed to parse \(configURL.path). Fix the JSON syntax and retry.") }
            config = decoded
        } else {
            config = [:]
        }
        var plugins = Self.openCodePluginListRemovingSessionPlugin((config["plugin"] as? [Any]) ?? [])
        if shouldInstall, !Self.openCodePluginListContains(plugins, spec: Self.openCodeSessionPluginConfigSpec) { plugins.append(Self.openCodeSessionPluginConfigSpec) }
        config["plugin"] = plugins
        let output = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        if existingData == output { return false }
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try output.write(to: configURL, options: .atomic)
        return true
    }

    func installOpenCodePluginHooks(_ def: AgentHookDef) throws {
        let pluginURL = openCodeSessionPluginURL(for: def)
        let skipConfirm = ProcessInfo.processInfo.arguments.contains("--yes") || ProcessInfo.processInfo.arguments.contains("-y")
        let existing = (try? String(contentsOf: pluginURL, encoding: .utf8)) ?? ""
        let configDir = URL(fileURLWithPath: def.resolvedConfigDir(), isDirectory: true)
        if existing == Self.openCodeSessionPluginSource {
            print(try updateOpenCodePluginRegistration(configDir: configDir, shouldInstall: true) ? "OpenCode hooks installed at \(pluginURL.path)" : "OpenCode hooks already up to date at \(pluginURL.path)")
            return
        }
        if !existing.isEmpty, !existing.contains(Self.openCodeSessionPluginMarker) { throw CLIError(message: "\(pluginURL.path) exists and is not a cmux plugin; leaving it alone") }
        if !skipConfirm {
            print("Will write OpenCode cmux plugin to \(pluginURL.path):")
            print(Self.openCodeSessionPluginSource)
            print("\nProceed? [y/N] ", terminator: "")
            guard readLine()?.lowercased().hasPrefix("y") == true else {
                print("Aborted.")
                return
            }
        }
        try writeOpenCodeSessionPlugin(in: configDir)
        _ = try updateOpenCodePluginRegistration(configDir: configDir, shouldInstall: true)
        print("OpenCode hooks installed at \(pluginURL.path)")
    }

    func uninstallOpenCodePluginHooks(_ def: AgentHookDef) throws {
        let fm = FileManager.default
        let pluginURL = openCodeSessionPluginURL(for: def)
        guard fm.fileExists(atPath: pluginURL.path) else {
            print("No OpenCode cmux plugin found at \(pluginURL.path)")
            return
        }
        let existing = (try? String(contentsOf: pluginURL, encoding: .utf8)) ?? ""
        guard existing.contains(Self.openCodeSessionPluginMarker) else {
            print("Refusing to remove \(pluginURL.path): missing cmux marker")
            return
        }
        try fm.removeItem(at: pluginURL)
        _ = try updateOpenCodePluginRegistration(
            configDir: URL(fileURLWithPath: def.resolvedConfigDir(), isDirectory: true),
            shouldInstall: false
        )
        print("Removed OpenCode cmux plugin from \(pluginURL.path)")
    }

    /// Marker matching the `// cmux-feed-plugin-marker` line emitted at
    /// the top of the generated plugin JS. Lets us detect our own
    /// plugin file and upgrade/uninstall without touching user plugins.
    private static let openCodePluginMarker = "cmux-feed-plugin-marker"

    private static let openCodePluginFileName = "cmux-feed.js"

    private func openCodeConfigDirPath() -> String {
        if let override = ProcessInfo.processInfo.environment["OPENCODE_CONFIG_DIR"],
           !override.isEmpty {
            return NSString(string: override).expandingTildeInPath
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/opencode", isDirectory: true)
            .path
    }

    private func openCodePluginPath(projectLocal: Bool) -> String {
        if projectLocal {
            let cwd = FileManager.default.currentDirectoryPath
            return "\(cwd)/.opencode/plugins/\(Self.openCodePluginFileName)"
        }
        return "\(openCodeConfigDirPath())/plugins/\(Self.openCodePluginFileName)"
    }

    private func bundledOpenCodePluginSource() throws -> String {
        // The plugin JS is bundled into the .app via `Resources/opencode-plugin.js`.
        // The `cmux` CLI is often launched from `Contents/Resources/bin/cmux`,
        // where Bundle.main can be the CLI executable rather than the containing
        // app. Search the real executable path before falling back to repo dev
        // paths used by `swift run`-style local builds.
        for url in openCodePluginResourceCandidates() {
            if let contents = try? String(contentsOf: url, encoding: .utf8) {
                return contents
            }
        }
        throw CLIError(message: "bundled opencode-plugin.js not found (Bundle.main, app bundle, executable, and repo fallbacks)")
    }

    private func openCodePluginResourceCandidates() -> [URL] {
        let fileManager = FileManager.default
        var candidates: [URL] = []
        var seen: Set<String> = []

        func appendIfExisting(_ url: URL?) {
            guard let url else { return }
            let standardized = url.standardizedFileURL
            guard seen.insert(standardized.path).inserted else { return }
            guard fileManager.fileExists(atPath: standardized.path) else { return }
            candidates.append(standardized)
        }

        appendIfExisting(Bundle.main.url(forResource: "opencode-plugin", withExtension: "js"))
        appendIfExisting(Bundle.main.resourceURL?.appendingPathComponent("opencode-plugin.js", isDirectory: false))

        if let executableURL = resolvedExecutableURL() {
            let execDir = executableURL.deletingLastPathComponent().standardizedFileURL
            for relativePath in ["opencode-plugin.js", "../opencode-plugin.js", "../../Resources/opencode-plugin.js", "../../../Contents/Resources/opencode-plugin.js"] {
                appendIfExisting(execDir.appendingPathComponent(relativePath, isDirectory: false).standardizedFileURL)
            }

            var current = execDir
            for _ in 0..<4 {
                if current.pathExtension == "app" {
                    appendIfExisting(current.appendingPathComponent("Contents/Resources/opencode-plugin.js", isDirectory: false))
                    break
                }
                let projectMarker = current.appendingPathComponent("cmux.xcodeproj/project.pbxproj")
                let repoResource = current.appendingPathComponent("Resources/opencode-plugin.js", isDirectory: false)
                if fileManager.fileExists(atPath: projectMarker.path),
                   fileManager.fileExists(atPath: repoResource.path) {
                    appendIfExisting(repoResource)
                    break
                }
                current = current.deletingLastPathComponent().standardizedFileURL
            }
        }

        let devRelative = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/opencode-plugin.js")
        appendIfExisting(devRelative)
        return candidates
    }

    func installOpenCodePlugin(projectLocal: Bool) throws {
        let source = try bundledOpenCodePluginSource()
        let path = openCodePluginPath(projectLocal: projectLocal)
        let fm = FileManager.default
        // If an existing non-cmux plugin lives at the same path, refuse
        // to overwrite. Users can delete it manually or pick a different
        // name; we never clobber user content.
        let existing = fm.fileExists(atPath: path)
            ? ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "")
            : ""
        if !existing.isEmpty, !existing.contains(Self.openCodePluginMarker) {
            throw CLIError(message: "\(path) exists and is not a cmux plugin; leaving it alone")
        }
        let parent = (path as NSString).deletingLastPathComponent
        try fm.createDirectory(
            atPath: parent, withIntermediateDirectories: true
        )
        let skipConfirm = ProcessInfo.processInfo.arguments.contains("--yes")
            || ProcessInfo.processInfo.arguments.contains("-y")
        if existing == source {
            print("OpenCode plugin already up to date at \(path)")
            return
        }
        if !skipConfirm {
            Self.printInstallPreview(
                path: path,
                oldContent: existing,
                newContent: source,
                fallbackContent: source
            )
            print("\nProceed? [y/N] ", terminator: "")
            guard readLine()?.lowercased().hasPrefix("y") == true else {
                print("Aborted.")
                return
            }
        }
        try source.write(toFile: path, atomically: true, encoding: .utf8)
        print("OpenCode plugin installed at \(path)")
    }

    func uninstallOpenCodePlugin(projectLocal: Bool = false) throws {
        let fm = FileManager.default
        for path in [openCodePluginPath(projectLocal: false),
                     openCodePluginPath(projectLocal: true)] {
            guard fm.fileExists(atPath: path) else { continue }
            guard let existing = try? String(contentsOfFile: path, encoding: .utf8),
                  existing.contains(Self.openCodePluginMarker)
            else {
                print("Skipping \(path) (no cmux marker)")
                continue
            }
            try fm.removeItem(atPath: path)
            print("OpenCode plugin removed from \(path)")
        }
    }

    // MARK: - Feed (workstream) hook bridge

}
