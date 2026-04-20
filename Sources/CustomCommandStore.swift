import AppKit
import Foundation

final class CustomCommandStore {
    static let shared = CustomCommandStore()

    private struct ResolvedBinding {
        let binding: CustomCommandBinding
        let shortcut: StoredShortcut
    }

    private let fileManager: FileManager
    private let path: String
    private var watcher: ShortcutSettingsFileWatcher?
    private var bindings: [ResolvedBinding] = []

    init(
        fileManager: FileManager = .default,
        path: String? = nil
    ) {
        self.fileManager = fileManager
        self.path = path ?? Self.defaultPath(fileManager: fileManager)
        watcher = ShortcutSettingsFileWatcher(path: self.path, fileManager: fileManager) { [weak self] in
            DispatchQueue.main.async {
                self?.reload()
            }
        }
        reload()
    }

    func reload() {
        guard fileManager.fileExists(atPath: path),
              let data = fileManager.contents(atPath: path),
              !data.isEmpty else {
            bindings = []
            return
        }

        do {
            let sanitized = try JSONCParser.preprocess(data: data)
            let schema = try JSONDecoder().decode(KeybindingsConfigFile.Schema.self, from: sanitized)
            bindings = resolveBindings(schema.custom_commands ?? [])
        } catch {
            NSLog("[CustomCommandStore] parse error at %@: %@", path, String(describing: error))
            bindings = []
        }
    }

    func matchingCommand(for event: NSEvent) -> CustomCommandBinding? {
        bindings.first { $0.shortcut.matches(event: event) }?.binding
    }

    private func resolveBindings(_ rawBindings: [CustomCommandBinding]) -> [ResolvedBinding] {
        var seenIDs = Set<String>()
        var resolved: [ResolvedBinding] = []

        for binding in rawBindings {
            let id = binding.id.trimmingCharacters(in: .whitespacesAndNewlines)
            let shortcutString = binding.shortcut.trimmingCharacters(in: .whitespacesAndNewlines)
            let command = binding.command.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !id.isEmpty else {
                NSLog("[CustomCommandStore] ignoring custom command with empty id in %@", path)
                continue
            }
            guard seenIDs.insert(id).inserted else {
                NSLog("[CustomCommandStore] ignoring duplicate custom command id '%@' in %@", id, path)
                continue
            }
            guard !shortcutString.isEmpty,
                  let shortcut = StoredShortcut.parse(rawValue: shortcutString),
                  !shortcut.hasChord else {
                NSLog("[CustomCommandStore] ignoring custom command '%@' with invalid shortcut '%@' in %@", id, binding.shortcut, path)
                continue
            }
            guard !command.isEmpty else {
                NSLog("[CustomCommandStore] ignoring custom command '%@' with empty command in %@", id, path)
                continue
            }

            resolved.append(
                ResolvedBinding(
                    binding: CustomCommandBinding(
                        id: id,
                        shortcut: shortcutString,
                        command: command,
                        label: binding.label?.trimmingCharacters(in: .whitespacesAndNewlines),
                        target: binding.target,
                        cwd: binding.cwd
                    ),
                    shortcut: shortcut
                )
            )
        }

        return resolved
    }

    private static func defaultPath(fileManager: FileManager) -> String {
        let home = fileManager.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(".config/cmux/keybindings.json")
    }
}
