import CMUXAgentLaunch
import Foundation

extension CMUXCLI {
    /// Mirrors Code Puppy's CONFIG_DIR, not the unsupported CODE_PUPPY_HOME variable.
    static func codePuppyConfigDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg).appendingPathComponent("code_puppy")
        }
        let home = environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        return URL(fileURLWithPath: home).appendingPathComponent(".code_puppy")
    }

    private struct CodePuppyFileEdit {
        let url: URL
        let old: Data?
        let new: Data?
    }

    func installCodePuppyPlugin(_ def: AgentHookDef) throws {
        let directory = Self.codePuppyConfigDirectory()
        let pluginDirectory = directory.appendingPathComponent("plugins/cmux-session")
        let moduleURL = pluginDirectory.appendingPathComponent("register_callbacks.py")
        let registryURL = directory.appendingPathComponent(CodePuppyPlugin.registryFileName)
        guard let executable = Self.pinnedAgentHookCLIPath() else {
            throw CLIError(message: String(
                localized: "cli.hooks.error.pinnedTargetMissing",
                defaultValue: "cmux could not connect this hook installation to a running app. Open a cmux workspace and run this command again."
            ))
        }
        let oldModule = try codePuppyOwnedModule(at: moduleURL)
        let oldRegistry = try codePuppyFileData(at: registryURL)
        let registry: Data
        do {
            registry = try CodePuppyPlugin.installing(
                registryData: oldRegistry, pluginPath: pluginDirectory.path
            )
        } catch {
            throw codePuppyOwnershipError(registryURL)
        }
        let source = CodePuppyPlugin.render(
            cmuxExecutablePath: executable, socketPath: Self.pinnedAgentHookSocketPath()
        )
        var edits = [
            CodePuppyFileEdit(url: moduleURL, old: oldModule, new: Data(source.utf8)),
            CodePuppyFileEdit(url: registryURL, old: oldRegistry, new: registry),
        ]
        // Remove only our legacy native hook entries, otherwise callbacks would dispatch twice.
        // Native hooks cannot carry canonical autosave IDs or completion outcomes.
        let legacyURL = directory.appendingPathComponent("hooks.json")
        if let old = try codePuppyFileData(at: legacyURL) {
            let new = try removingCodePuppyNativeHooks(old, at: legacyURL, def: def)
            if old != new { edits.append(CodePuppyFileEdit(url: legacyURL, old: old, new: new)) }
        }
        edits.removeAll { $0.old == $0.new }
        guard !edits.isEmpty else {
            print(String.localizedStringWithFormat(
                String(localized: "cli.hooks.kimi.alreadyUpToDate", defaultValue: "%@ hooks already up to date at %@"),
                def.displayName, moduleURL.path
            ))
            return
        }
        let skipConfirm = ProcessInfo.processInfo.arguments.contains("--yes")
            || ProcessInfo.processInfo.arguments.contains("-y")
        if !skipConfirm {
            for edit in edits {
                let old = edit.old.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let new = edit.new.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                Self.printInstallPreview(path: edit.url.path, oldContent: old, newContent: new, fallbackContent: new)
            }
            print(String(localized: "cli.hooks.kimi.confirmProceed", defaultValue: "\nProceed? [y/N] "), terminator: "")
            guard readLine()?.lowercased().hasPrefix("y") == true else {
                print(String(localized: "cli.hooks.kimi.aborted", defaultValue: "Aborted."))
                return
            }
        }
        try applyCodePuppyEdits(edits)
        print(String.localizedStringWithFormat(
            String(localized: "cli.hooks.kimi.installed", defaultValue: "%@ hooks installed at %@"),
            def.displayName, moduleURL.path
        ))
    }

    func uninstallCodePuppyPlugin(_ def: AgentHookDef) throws {
        let directory = Self.codePuppyConfigDirectory()
        let pluginDirectory = directory.appendingPathComponent("plugins/cmux-session")
        let moduleURL = pluginDirectory.appendingPathComponent("register_callbacks.py")
        let registryURL = directory.appendingPathComponent(CodePuppyPlugin.registryFileName)
        let module = try codePuppyOwnedModule(at: moduleURL)
        let registry = try codePuppyFileData(at: registryURL)
        let updated: Data?
        do {
            updated = try CodePuppyPlugin.uninstalling(registryData: registry, pluginPath: pluginDirectory.path)
        } catch {
            throw codePuppyOwnershipError(registryURL)
        }
        var edits = [
            CodePuppyFileEdit(url: moduleURL, old: module, new: nil),
            CodePuppyFileEdit(url: registryURL, old: registry, new: updated),
        ]
        let legacyURL = directory.appendingPathComponent("hooks.json")
        if let old = try codePuppyFileData(at: legacyURL) {
            let new = try removingCodePuppyNativeHooks(old, at: legacyURL, def: def)
            edits.append(CodePuppyFileEdit(url: legacyURL, old: old, new: new))
        }
        try applyCodePuppyEdits(edits.filter { $0.old != $0.new })
        // Keep the directory and any unrelated files; only the owned module is removed.
        print(moduleURL.path)
    }

    private func codePuppyOwnershipError(_ url: URL) -> CLIError {
        CLIError(message: String.localizedStringWithFormat(
            String(localized: "cli.hooks.pi.error.notCmuxExtension", defaultValue: "%@ exists and is not a cmux extension; leaving it alone"),
            url.path
        ))
    }

    private func codePuppyFileData(at url: URL) throws -> Data? {
        // Never follow symlinks into another plugin or arbitrary user files.
        var ancestor = url
        while ancestor.path != "/" {
            if let type = try? FileManager.default.attributesOfItem(atPath: ancestor.path)[.type],
               type as? FileAttributeType == .typeSymbolicLink {
                throw codePuppyOwnershipError(ancestor)
            }
            ancestor.deleteLastPathComponent()
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    private func codePuppyOwnedModule(at url: URL) throws -> Data? {
        guard let data = try codePuppyFileData(at: url) else { return nil }
        guard let text = String(data: data, encoding: .utf8),
              text.contains("# cmux-managed Code Puppy plugin v1.") else {
            throw codePuppyOwnershipError(url)
        }
        return data
    }

    private func removingCodePuppyNativeHooks(_ data: Data, at url: URL, def: AgentHookDef) throws -> Data {
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw codePuppyOwnershipError(url)
        }
        let wrapped = root["hooks"] != nil
        guard var hooks = (wrapped ? root["hooks"] : root) as? [String: Any] else {
            throw codePuppyOwnershipError(url)
        }
        var changed = false
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            var retained: [[String: Any]] = []
            for var group in groups {
                guard let entries = group["hooks"] as? [[String: Any]] else {
                    retained.append(group)
                    continue
                }
                let remaining = entries.filter {
                    !Self.isCmuxOwnedHookCommand($0["command"] as? String ?? "", for: def)
                }
                changed = changed || remaining.count != entries.count
                if !remaining.isEmpty {
                    group["hooks"] = remaining
                    retained.append(group)
                }
            }
            if retained.isEmpty { hooks.removeValue(forKey: event) }
            else { hooks[event] = retained }
        }
        guard changed else { return data }
        if wrapped { root["hooks"] = hooks } else { root = hooks }
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    private func applyCodePuppyEdits(_ edits: [CodePuppyFileEdit]) throws {
        var applied: [CodePuppyFileEdit] = []
        do {
            for edit in edits {
                // Reject concurrent edits rather than overwrite someone else's update.
                guard try codePuppyFileData(at: edit.url) == edit.old else {
                    throw codePuppyOwnershipError(edit.url)
                }
                if let data = edit.new {
                    try FileManager.default.createDirectory(at: edit.url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: edit.url, options: .atomic)
                } else if edit.old != nil {
                    try FileManager.default.removeItem(at: edit.url)
                }
                applied.append(edit)
            }
        } catch {
            for edit in applied.reversed() {
                if let old = edit.old { try? old.write(to: edit.url, options: .atomic) }
                else { try? FileManager.default.removeItem(at: edit.url) }
            }
            throw error
        }
    }
}
