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


// MARK: - Agent hook install/uninstall
extension CMUXCLI {
    // MARK: Generic hook install/uninstall
    func hookCommand(for def: AgentHookDef, event: AgentHookDef.HookEvent) -> String {
        Self.hookCommandString(for: def, event: event)
    }

    /// Shell command the agent runs for a Feed bridge event. 120s timeout
    /// inside the shell is applied via the agent's `timeout` field in the
    /// nested hook config (see `buildHooksDict`); the shell command
    /// itself just dispatches.
    func feedHookCommand(for def: AgentHookDef, agentEvent: String) -> String {
        Self.feedHookCommandString(for: def, agentEvent: agentEvent)
    }

    func buildHooksDict(for def: AgentHookDef) -> [String: Any] {
        var result: [String: Any] = [:]
        for event in def.events {
            let cmd = hookCommand(for: def, event: event)
            switch def.format {
            case .flat:
                var entries = result[event.agentEvent] as? [[String: Any]] ?? []
                entries.append(["command": cmd])
                result[event.agentEvent] = entries
            case .kiroAgentJSON(let timeoutMs):
                var entries = result[event.agentEvent] as? [[String: Any]] ?? []
                entries.append([
                    "command": cmd,
                    "timeout_ms": max(timeoutMs, 1),
                ] as [String: Any])
                result[event.agentEvent] = entries
            case .nested(let timeoutMs):
                var groups = result[event.agentEvent] as? [[String: Any]] ?? []
                let timeout = nestedHookTimeout(timeoutMs, for: def)
                groups.append([
                    "hooks": [["type": "command", "command": cmd, "timeout": timeout] as [String: Any]]
                ] as [String: Any])
                result[event.agentEvent] = groups
            case .antigravityJSON(let timeoutSeconds):
                var entries = result[event.agentEvent] as? [[String: Any]] ?? []
                entries.append(Self.antigravityHookEntry(
                    command: cmd,
                    timeoutSeconds: timeoutSeconds,
                    eventName: event.agentEvent
                ))
                result[event.agentEvent] = entries
            case .rovoDevYAML, .hermesAgentYAML:
                break
            }
        }
        // Layer in Feed bridge entries. Blocking approval bridges get a long
        // timeout; Codex telemetry stays short so it never delays Codex's own
        // approval reviewer. Most nested agents use milliseconds. Codex, Grok,
        // and Antigravity hook schemas use seconds, so normalize before writing.
        for agentEvent in def.feedHookEvents {
            let feedCmd = feedHookCommand(for: def, agentEvent: agentEvent)
            let feedTimeoutMs = feedHookTimeoutMs(for: def, agentEvent: agentEvent)
            switch def.format {
            case .flat:
                var entries = result[agentEvent] as? [[String: Any]] ?? []
                entries.append(["command": feedCmd])
                result[agentEvent] = entries
            case .kiroAgentJSON:
                var entries = result[agentEvent] as? [[String: Any]] ?? []
                entries.append([
                    "command": feedCmd,
                    "timeout_ms": feedTimeoutMs,
                ] as [String: Any])
                result[agentEvent] = entries
            case .nested:
                var groups = result[agentEvent] as? [[String: Any]] ?? []
                let timeout = nestedFeedHookTimeout(feedTimeoutMs, for: def)
                groups.append([
                    "hooks": [["type": "command", "command": feedCmd, "timeout": timeout] as [String: Any]]
                ] as [String: Any])
                result[agentEvent] = groups
            case .antigravityJSON:
                var entries = result[agentEvent] as? [[String: Any]] ?? []
                entries.append(Self.antigravityHookEntry(
                    command: feedCmd,
                    timeoutSeconds: Self.timeoutSecondsFromMilliseconds(feedTimeoutMs),
                    eventName: agentEvent
                ))
                result[agentEvent] = entries
            case .rovoDevYAML, .hermesAgentYAML:
                break
            }
        }
        return result
    }

    private func nestedHookTimeout(_ timeoutMs: Int, for def: AgentHookDef) -> Int {
        guard def.name == "grok" else { return max(timeoutMs, 1) }
        return Self.timeoutSecondsFromMilliseconds(timeoutMs)
    }

    private func nestedFeedHookTimeout(_ timeoutMs: Int, for def: AgentHookDef) -> Int {
        guard def.name == "codex" || def.name == "grok" else { return max(timeoutMs, 1) }
        return Self.timeoutSecondsFromMilliseconds(timeoutMs)
    }

    private func feedHookTimeoutMs(for def: AgentHookDef, agentEvent _: String) -> Int {
        if def.name == "codex" {
            return 5_000
        }
        return 120_000
    }

    private static func timeoutSecondsFromMilliseconds(_ timeoutMs: Int) -> Int {
        let positiveTimeoutMs = max(timeoutMs, 1)
        return ((positiveTimeoutMs - 1) / 1000) + 1
    }

    private static func antigravityHookEntry(
        command: String,
        timeoutSeconds: Int,
        eventName: String
    ) -> [String: Any] {
        let hook: [String: Any] = [
            "type": "command",
            "command": command,
            "timeout": max(timeoutSeconds, 1),
        ]
        switch eventName {
        case "PreToolUse", "PostToolUse":
            return [
                "matcher": "*",
                "hooks": [hook],
            ]
        default:
            return hook
        }
    }
    func installAgentHooks(_ def: AgentHookDef) throws {
        if def.name == "opencode" {
            try installOpenCodePluginHooks(def)
            return
        }
        if def.name == "pi" {
            try installPiExtensionHooks(def)
            return
        }
        if def.name == "omp" {
            try installOmpExtensionHooks(def)
            return
        }
        if def.name == "amp" {
            try installAmpExtensionHooks(def)
            return
        }
        if def.name == "rovodev" {
            try installRovoDevHooks(def)
            return
        }
        if def.name == "hermes-agent" {
            try installHermesAgentHooks(def)
            return
        }
        if case .antigravityJSON = def.format {
            try installAntigravityHooks(def)
            return
        }

        let fm = FileManager.default
        let configDir = def.resolvedConfigDir()
        let filePath = "\(configDir)/\(def.configFile)"
        let skipConfirm = ProcessInfo.processInfo.arguments.contains("--yes")
            || ProcessInfo.processInfo.arguments.contains("-y")

        let configDirectoryFileError = String.localizedStringWithFormat(
            String(
                localized: "cli.hooks.error.configDirectoryIsFile",
                defaultValue: "cmux could not create the hooks directory: a file exists at %@; remove or rename the conflicting file and re-run `cmux hooks setup`"
            ),
            configDir
        )
        var isConfigDirectory: ObjCBool = false
        let configPathExists = fm.fileExists(atPath: configDir, isDirectory: &isConfigDirectory)
        if configPathExists, !isConfigDirectory.boolValue {
            if def.createConfigDirIfMissing {
                throw CLIError(message: configDirectoryFileError)
            }
            print("Required agent configuration is missing. Run `cmux hooks setup` after installing your agent CLI.")
            return
        }
        if !configPathExists {
            if def.createConfigDirIfMissing {
                do {
                    try fm.createDirectory(atPath: configDir, withIntermediateDirectories: true)
                } catch {
                    throw CLIError(message: configDirectoryFileError)
                }
            } else {
                print("Required agent configuration is missing. Run `cmux hooks setup` after installing your agent CLI.")
                return
            }
        }

        var existing: [String: Any] = [:]
        if let data = fm.contents(atPath: filePath) {
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CLIError(message: "\(filePath) exists but is not valid JSON. Fix or remove it before installing hooks.")
            }
            existing = json
        }

        var hooks = existing["hooks"] as? [String: Any] ?? [:]
        let newHooks = buildHooksDict(for: def)

        // Remove existing cmux-owned entries (both the per-agent hook
        // dispatcher and the Feed bridge). Non-cmux entries are
        // always preserved, even when the user mixed them into the
        // same group as a cmux hook, we only prune our own entries
        // within that group so the user's stays put.
        let isCmuxOwnedCommand: (String) -> Bool = { cmd in
            Self.isCmuxOwnedHookCommand(cmd, for: def)
        }
        var cmuxInsertionIndexes: [String: [Int]] = [:]
        for (event, value) in hooks {
            switch def.format {
            case .flat, .kiroAgentJSON:
                guard let entries = value as? [[String: Any]] else { continue }
                var rewrittenEntries: [[String: Any]] = []
                for entry in entries {
                    if isCmuxOwnedCommand(entry["command"] as? String ?? "") {
                        Self.appendCmuxHookInsertionIndex(
                            rewrittenEntries.count,
                            for: event,
                            to: &cmuxInsertionIndexes
                        )
                        continue
                    }
                    rewrittenEntries.append(entry)
                }
                if rewrittenEntries.isEmpty {
                    hooks.removeValue(forKey: event)
                } else {
                    hooks[event] = rewrittenEntries
                }
            case .nested:
                guard let groups = value as? [[String: Any]] else { continue }
                var rewrittenGroups: [[String: Any]] = []
                for var group in groups {
                    guard var hookList = group["hooks"] as? [[String: Any]] else {
                        // Unknown shape: preserve verbatim so we don't
                        // accidentally mutate user custom data.
                        rewrittenGroups.append(group)
                        continue
                    }
                    if hookList.contains(where: { isCmuxOwnedCommand($0["command"] as? String ?? "") }) {
                        Self.appendCmuxHookInsertionIndex(
                            rewrittenGroups.count,
                            for: event,
                            to: &cmuxInsertionIndexes
                        )
                    }
                    hookList.removeAll { isCmuxOwnedCommand($0["command"] as? String ?? "") }
                    if hookList.isEmpty {
                        // Fully cmux-owned group, drop it entirely.
                        continue
                    }
                    group["hooks"] = hookList
                    rewrittenGroups.append(group)
                }
                if rewrittenGroups.isEmpty {
                    hooks.removeValue(forKey: event)
                } else {
                    hooks[event] = rewrittenGroups
                }
            case .antigravityJSON, .rovoDevYAML, .hermesAgentYAML:
                break
            }
        }

        // Add new cmux entries
        for (event, value) in newHooks {
            switch def.format {
            case .flat, .kiroAgentJSON:
                var entries = hooks[event] as? [[String: Any]] ?? []
                if let newEntries = value as? [[String: Any]] {
                    if let insertionIndexes = cmuxInsertionIndexes[event], !insertionIndexes.isEmpty {
                        Self.insertCmuxHookValues(newEntries, into: &entries, atOriginalIndexes: insertionIndexes)
                    } else {
                        entries.append(contentsOf: newEntries)
                    }
                }
                hooks[event] = entries
            case .nested:
                var groups = hooks[event] as? [[String: Any]] ?? []
                if let newGroups = value as? [[String: Any]] {
                    if let insertionIndexes = cmuxInsertionIndexes[event], !insertionIndexes.isEmpty {
                        Self.insertCmuxHookValues(newGroups, into: &groups, atOriginalIndexes: insertionIndexes)
                    } else {
                        groups.append(contentsOf: newGroups)
                    }
                }
                hooks[event] = groups
            case .antigravityJSON, .rovoDevYAML, .hermesAgentYAML:
                break
            }
        }

        existing["hooks"] = hooks
        if case .flat = def.format { existing["version"] = 1 }
        if case .kiroAgentJSON = def.format {
            if existing["name"] == nil {
                existing["name"] = "cmux"
            }
            if existing["description"] == nil {
                existing["description"] = "CMUX notification and Feed bridge hooks for Kiro CLI."
            }
            if existing["tools"] == nil {
                // Grant the full tool set so `kiro-cli chat --agent cmux` is
                // actually usable. A Kiro custom agent with no `tools` field is
                // restricted to no tools, so the model can't run anything and the
                // preToolUse/postToolUse Feed-approval hooks would never fire
                // (verified against kiro-cli 2.5.0). Only defaulted on fresh
                // install; an existing user `tools` list is preserved.
                existing["tools"] = ["*"]
            }
        }
        let codexHookTrustEntries = Self.codexHookTrustEntries(
            hooks: hooks,
            hooksFilePath: filePath,
            def: def
        )
        let codexHookTrustEscapedKeyPrefixes = Self.codexHookTrustEscapedKeyPrefixes(
            hooksFilePath: filePath,
            def: def
        )
        let codexLegacyHookTrustHashes = Self.codexLegacyHookTrustHashes(def: def)

        let newData = try JSONSerialization.data(withJSONObject: existing, options: [.prettyPrinted, .sortedKeys])
        let newString = String(data: newData, encoding: .utf8) ?? "{}"
        let oldString: String = {
            if let data = fm.contents(atPath: filePath),
               let json = try? JSONSerialization.jsonObject(with: data),
               let pretty = try? JSONSerialization.data(
                    withJSONObject: json, options: [.prettyPrinted, .sortedKeys]
               ),
               let s = String(data: pretty, encoding: .utf8)
            {
                return s
            }
            return ""
        }()

        if oldString == newString {
            // No-op install; skip the write and the prompt entirely.
            print("\(def.displayName) hooks already up to date at \(filePath)")
        } else {
            if !skipConfirm {
                Self.printInstallPreview(
                    path: filePath,
                    oldContent: oldString,
                    newContent: newString,
                    fallbackContent: newString
                )
                print("\nProceed? [y/N] ", terminator: "")
                guard readLine()?.lowercased().hasPrefix("y") == true else {
                    print("Aborted.")
                    return
                }
            }
            try newData.write(to: URL(fileURLWithPath: filePath), options: .atomic)
            print("\(def.displayName) hooks installed at \(filePath)")
        }

        if let note = def.postInstallNote {
            print(note)
        }

        try pruneLegacyGrokHookFileIfNeeded(def: def, configDir: configDir, primaryFilePath: filePath)

        // Post-install actions
        if let action = def.postInstallAction {
            switch action {
            case .codexConfigToml:
                let configPath = "\(configDir)/config.toml"
                let existingContent: String
                if fm.fileExists(atPath: configPath) {
                    existingContent = try String(contentsOfFile: configPath, encoding: .utf8)
                } else {
                    existingContent = ""
                }
                let trustClean = Self.codexConfigTomlRemovingHookTrust(
                    in: existingContent,
                    entries: codexHookTrustEntries,
                    removingEscapedKeyPrefixes: codexHookTrustEscapedKeyPrefixes,
                    removingTrustedHashes: codexLegacyHookTrustHashes
                )
                let featureContent = Self.codexConfigTomlInstallingHooksFeature(in: trustClean)
                let trustInstall = Self.codexConfigTomlInstallingHookTrust(
                    in: featureContent,
                    entries: codexHookTrustEntries,
                    removingEscapedKeyPrefixes: codexHookTrustEscapedKeyPrefixes,
                    removingTrustedHashes: codexLegacyHookTrustHashes
                )
                let newContent = trustInstall.content
                if newContent != existingContent {
                    if !skipConfirm {
                        Self.printInstallPreview(
                            path: configPath,
                            oldContent: existingContent,
                            newContent: newContent,
                            fallbackContent: newContent
                        )
                        print("\nProceed? [y/N] ", terminator: "")
                        guard readLine()?.lowercased().hasPrefix("y") == true else {
                            print("Aborted (\(configPath) unchanged).")
                            return
                        }
                    }
                    try newContent.write(toFile: configPath, atomically: true, encoding: .utf8)
                    if def.name == "codex", !codexHookTrustEntries.isEmpty, trustInstall.installedTrust {
                        print("Enabled hooks and approved cmux hooks in \(configPath)")
                    } else {
                        print("Enabled hooks in \(configPath)")
                    }
                }
            }
        }
    }

    private func pruneLegacyGrokHookFileIfNeeded(
        def: AgentHookDef,
        configDir: String,
        primaryFilePath: String
    ) throws {
        guard def.name == "grok" else { return }
        let legacyURL = URL(fileURLWithPath: configDir, isDirectory: true)
            .appendingPathComponent("cmux.json", isDirectory: false)
        guard legacyURL.path != primaryFilePath,
              FileManager.default.fileExists(atPath: legacyURL.path),
              let data = FileManager.default.contents(atPath: legacyURL.path),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var hooks = json["hooks"] as? [String: Any] else {
            return
        }

        let isCmuxOwnedCommand: (String) -> Bool = { cmd in
            Self.isCmuxOwnedHookCommand(cmd, for: def)
        }
        var removed = 0
        for (event, value) in hooks {
            guard var entries = value as? [[String: Any]] else { continue }
            let containsNestedGroups = entries.contains { $0["hooks"] is [[String: Any]] }
            if !containsNestedGroups {
                let before = entries.count
                entries.removeAll { isCmuxOwnedCommand($0["command"] as? String ?? "") }
                removed += before - entries.count
                if entries.isEmpty {
                    hooks.removeValue(forKey: event)
                } else {
                    hooks[event] = entries
                }
                continue
            }
            var rewrittenGroups: [[String: Any]] = []
            for var group in entries {
                guard var hookList = group["hooks"] as? [[String: Any]] else {
                    rewrittenGroups.append(group)
                    continue
                }
                let before = hookList.count
                hookList.removeAll { isCmuxOwnedCommand($0["command"] as? String ?? "") }
                removed += before - hookList.count
                guard !hookList.isEmpty else { continue }
                group["hooks"] = hookList
                rewrittenGroups.append(group)
            }
            if rewrittenGroups.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = rewrittenGroups
            }
        }

        guard removed > 0 else { return }
        if hooks.isEmpty {
            json.removeValue(forKey: "hooks")
            if json.isEmpty {
                try FileManager.default.removeItem(at: legacyURL)
                print("Removed legacy \(def.displayName) hooks at \(legacyURL.path)")
                return
            }
        } else {
            json["hooks"] = hooks
        }
        let newData = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try newData.write(to: legacyURL, options: .atomic)
        print("Removed \(removed) legacy \(def.displayName) cmux hook(s) from \(legacyURL.path)")
    }

    func uninstallAgentHooks(_ def: AgentHookDef) throws {
        if def.name == "opencode" {
            try uninstallOpenCodePluginHooks(def)
            return
        }
        if def.name == "pi" {
            try uninstallPiExtensionHooks(def)
            return
        }
        if def.name == "omp" {
            try uninstallOmpExtensionHooks(def)
            return
        }
        if def.name == "amp" {
            try uninstallAmpExtensionHooks(def)
            return
        }
        if def.name == "rovodev" {
            try uninstallRovoDevHooks(def)
            return
        }
        if def.name == "hermes-agent" {
            try uninstallHermesAgentHooks(def)
            return
        }
        if case .antigravityJSON = def.format {
            try uninstallAntigravityHooks(def)
            return
        }

        let fm = FileManager.default
        let configDir = def.resolvedConfigDir()
        let filePath = "\(configDir)/\(def.configFile)"

        guard let data = fm.contents(atPath: filePath),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("No \(def.configFile) found at \(filePath)")
            return
        }

        var hooks = json["hooks"] as? [String: Any] ?? [:]
        let codexHookTrustEntriesToRemove = Self.codexHookTrustEntries(
            hooks: hooks,
            hooksFilePath: filePath,
            def: def,
            includeLegacyOwnedCommands: true
        )
        let codexStaleHookTrustHashesToRemove = Set(Self.codexHookTrustEntries(
            hooks: buildHooksDict(for: def),
            hooksFilePath: filePath,
            def: def
        ).map(\.trustedHash)).union(Self.codexLegacyHookTrustHashes(def: def))
        let codexHookTrustEscapedKeyPrefixesToRemove = Self.codexHookTrustEscapedKeyPrefixes(
            hooksFilePath: filePath,
            def: def
        )
        var removed = 0

        let isCmuxOwnedCommand: (String) -> Bool = { cmd in
            Self.isCmuxOwnedHookCommand(cmd, for: def)
        }
        for (event, value) in hooks {
            switch def.format {
            case .flat, .kiroAgentJSON:
                guard var entries = value as? [[String: Any]] else { continue }
                let before = entries.count
                entries.removeAll { isCmuxOwnedCommand($0["command"] as? String ?? "") }
                removed += before - entries.count
                if entries.isEmpty {
                    hooks.removeValue(forKey: event)
                } else {
                    hooks[event] = entries
                }
            case .nested:
                guard let groups = value as? [[String: Any]] else { continue }
                var rewrittenGroups: [[String: Any]] = []
                for var group in groups {
                    guard var hookList = group["hooks"] as? [[String: Any]] else {
                        rewrittenGroups.append(group)
                        continue
                    }
                    let before = hookList.count
                    hookList.removeAll { isCmuxOwnedCommand($0["command"] as? String ?? "") }
                    removed += before - hookList.count
                    if hookList.isEmpty { continue }
                    group["hooks"] = hookList
                    rewrittenGroups.append(group)
                }
                if rewrittenGroups.isEmpty {
                    hooks.removeValue(forKey: event)
                } else {
                    hooks[event] = rewrittenGroups
                }
            case .antigravityJSON, .rovoDevYAML, .hermesAgentYAML:
                break
            }
        }

        json["hooks"] = hooks
        let newData = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try newData.write(to: URL(fileURLWithPath: filePath), options: .atomic)
        print("Removed \(removed) cmux hook(s) from \(filePath)")

        // Post-uninstall actions
        if let action = def.postInstallAction {
            switch action {
            case .codexConfigToml:
                let configPath = "\(configDir)/config.toml"
                guard fm.fileExists(atPath: configPath) else { return }
                let content: String
                do {
                    content = try String(contentsOfFile: configPath, encoding: .utf8)
                } catch {
                    throw CLIError(message: "\(configPath) exists but could not be read. Fix permissions or remove it before uninstalling \(def.displayName) hooks. \(String(describing: error))")
                }
                let newContent = Self.codexConfigTomlUninstallingHooksFeature(
                    from: content,
                    removingHookTrustEntries: codexHookTrustEntriesToRemove,
                    removingEscapedKeyPrefixes: codexHookTrustEscapedKeyPrefixesToRemove,
                    removingTrustedHashes: codexStaleHookTrustHashesToRemove
                )
                if newContent != content {
                    try newContent.write(toFile: configPath, atomically: true, encoding: .utf8)
                    print("Removed Codex hooks feature from \(configPath)")
                }
            }
        }
    }

}
