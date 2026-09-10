import CMUXAgentLaunch
import Darwin
import Foundation

extension CMUXCLI {
    private static let vibeLifecycleHookTimeoutSeconds: Double = 60
    private static let vibeFeedHookTimeoutSeconds: Double = 120

    /// Builds the lifecycle and feed hook events for a Vibe agent definition.
    /// - Parameter def: The Vibe agent hook definition.
    /// - Returns: Vibe hook events ready for TOML serialization.
    func vibeHookEvents(def: AgentHookDef) -> [VibeHookConfig.Event] {
        var events = def.events.map { event in
            VibeHookConfig.Event(
                name: "cmux-\(event.cmuxSubcommand)",
                type: event.agentEvent,
                command: hookCommand(for: def, event: event),
                timeout: Self.vibeLifecycleHookTimeoutSeconds
            )
        }
        events.append(contentsOf: def.feedHookEvents.map { agentEvent in
            VibeHookConfig.Event(
                name: "cmux-feed-\(agentEvent)",
                type: agentEvent,
                command: feedHookCommand(for: def, agentEvent: agentEvent),
                timeout: Self.vibeFeedHookTimeoutSeconds
            )
        })
        return events
    }

    /// Acquires an exclusive `flock` on a sidecar lock file beside the config,
    /// then runs the read-transform-write sequence under that lock to serialize
    /// concurrent cmux invocations. After interactive confirmation, re-reads and
    /// recomputes so the preview matches what is actually written.
    private func withVibeConfigLock<T>(
        filePath: String,
        body: () throws -> T
    ) throws -> T {
        let lockPath = filePath + ".cmux-lock"
        let descriptor = open(lockPath, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else {
            throw CLIError(message: "cmux could not acquire config lock at \(lockPath)")
        }
        defer { _ = Darwin.close(descriptor) }
        var result: Int32
        repeat {
            result = flock(descriptor, LOCK_EX)
        } while result != 0 && errno == EINTR
        guard result == 0 else {
            throw CLIError(message: "cmux could not acquire config lock at \(lockPath)")
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }

    /// Installs cmux-owned hooks into the Vibe config file at `~/.vibe/hooks.toml`.
    /// - Parameter def: The Vibe agent hook definition.
    /// - Throws: A `CLIError` if the config directory is a file or cannot be created.
    func installVibeHooks(_ def: AgentHookDef) throws {
        let fm = FileManager.default
        let configDir = def.resolvedConfigDir()
        let filePath = "\(configDir)/\(def.configFile)"
        let events = vibeHookEvents(def: def)
        let skipConfirm = ProcessInfo.processInfo.arguments.contains("--yes")
            || ProcessInfo.processInfo.arguments.contains("-y")

        let configDirectoryFileError = String.localizedStringWithFormat(
            String(
                localized: "cli.hooks.error.configDirectoryIsFile",
                defaultValue: "cmux could not create the hooks directory: a file exists at %@. Remove or rename the conflicting file, then run `cmux hooks setup` again."
            ),
            configDir
        )
        var isConfigDirectory = ObjCBool(false)
        let configPathExists = fm.fileExists(atPath: configDir, isDirectory: &isConfigDirectory)
        if configPathExists, !isConfigDirectory.boolValue {
            throw CLIError(message: configDirectoryFileError)
        }

        try withVibeConfigLock(filePath: filePath) {
            let oldString = try readAgentHookConfig(filePath: filePath, displayName: def.displayName)
            let newString = VibeHookConfig().installing(events: events, in: oldString)

            if oldString == newString {
                print(String.localizedStringWithFormat(
                    String(
                        localized: "cli.hooks.vibe.alreadyUpToDate",
                        defaultValue: "%@ hooks already up to date at %@"
                    ),
                    def.displayName,
                    filePath
                ))
                return
            }

            if !skipConfirm {
                Self.printInstallPreview(
                    path: filePath,
                    oldContent: oldString,
                    newContent: newString,
                    fallbackContent: newString
                )
                print(String(
                    localized: "cli.hooks.vibe.confirmProceed",
                    defaultValue: "\nProceed? [y/N] "
                ), terminator: "")
                guard readLine()?.lowercased().hasPrefix("y") == true else {
                    print(String(
                        localized: "cli.hooks.vibe.aborted",
                        defaultValue: "Aborted."
                    ))
                    return
                }
                // Re-read and recompute under the lock so the preview matches
                // what is actually written if another process changed the file.
                let currentString = try readAgentHookConfig(filePath: filePath, displayName: def.displayName)
                let recomputed = VibeHookConfig().installing(events: events, in: currentString)
                guard currentString == oldString else {
                    Self.printInstallPreview(
                        path: filePath,
                        oldContent: currentString,
                        newContent: recomputed,
                        fallbackContent: recomputed
                    )
                    print(String(
                        localized: "cli.hooks.vibe.confirmProceed",
                        defaultValue: "\nProceed? [y/N] "
                    ), terminator: "")
                    guard readLine()?.lowercased().hasPrefix("y") == true else {
                        print(String(
                            localized: "cli.hooks.vibe.aborted",
                            defaultValue: "Aborted."
                        ))
                        return
                    }
                }
            }

            if !configPathExists {
                do {
                    try fm.createDirectory(atPath: configDir, withIntermediateDirectories: true)
                } catch {
                    throw CLIError(message: String.localizedStringWithFormat(
                        String(
                            localized: "cli.hooks.error.configDirectoryCreateFailed",
                            defaultValue: "cmux could not create the hooks directory at %@. Check the directory permissions, then run `cmux hooks setup` again."
                        ),
                        configDir
                    ))
                }
            }
            try newString.write(toFile: filePath, atomically: true, encoding: .utf8)
            print(String.localizedStringWithFormat(
                String(
                    localized: "cli.hooks.vibe.installed",
                    defaultValue: "%@ hooks installed at %@"
                ),
                def.displayName,
                filePath
            ))
        }
    }

    /// Removes cmux-owned hooks from the Vibe config file at `~/.vibe/hooks.toml`.
    /// - Parameter def: The Vibe agent hook definition.
    /// - Throws: A `CLIError` if the config file cannot be read or written.
    func uninstallVibeHooks(_ def: AgentHookDef) throws {
        let fm = FileManager.default
        let configDir = def.resolvedConfigDir()
        let filePath = "\(configDir)/\(def.configFile)"

        guard fm.fileExists(atPath: filePath) else {
            print(String.localizedStringWithFormat(
                String(
                    localized: "cli.hooks.vibe.noneFound",
                    defaultValue: "No %@ found at %@"
                ),
                def.configFile,
                filePath
            ))
            return
        }

        try withVibeConfigLock(filePath: filePath) {
            let oldString = try readAgentHookConfig(filePath: filePath, displayName: def.displayName)
            let newString = VibeHookConfig().uninstalling(from: oldString)

            guard oldString != newString else {
                print(String.localizedStringWithFormat(
                    String(
                        localized: "cli.hooks.vibe.removedZero",
                        defaultValue: "Removed 0 cmux hook(s) from %@"
                    ),
                    filePath
                ))
                return
            }

            try newString.write(toFile: filePath, atomically: true, encoding: .utf8)
            print(String.localizedStringWithFormat(
                String(
                    localized: "cli.hooks.vibe.removed",
                    defaultValue: "Removed %@ cmux hooks from %@"
                ),
                def.displayName,
                filePath
            ))
        }
    }
}
