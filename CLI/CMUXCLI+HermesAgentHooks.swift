import CMUXAgentLaunch
import Darwin
import Foundation

extension CMUXCLI {
    private static let hermesTUIActiveSessionFilePrefix = "hermes-tui-active-session-"
    private static let hermesTUIActiveSessionMaximumBytes: Int64 = 4_096

    private func updateHermesAgentAllowlist(
        atPath allowlistPath: String,
        transform: (Data?) throws -> Data
    ) throws -> Bool {
        let lockPath = "\(allowlistPath).lock"
        let descriptor = Darwin.open(
            lockPath,
            O_RDWR | O_CREAT | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { _ = Darwin.close(descriptor) }

        var result: Int32
        repeat {
            result = flock(descriptor, LOCK_EX)
        } while result != 0 && errno == EINTR
        guard result == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { _ = flock(descriptor, LOCK_UN) }

        let oldAllowlist = FileManager.default.contents(atPath: allowlistPath)
        let newAllowlist = try transform(oldAllowlist)
        guard oldAllowlist != newAllowlist else { return false }
        try newAllowlist.write(to: URL(fileURLWithPath: allowlistPath), options: .atomic)
        return true
    }

    private func hermesAgentApprovalPayload(
        def: AgentHookDef,
        input: ClaudeHookParsedInput
    ) -> (event: String, extra: [String: Any])? {
        guard def.name == "hermes-agent",
              let object = input.rawObject ?? input.object,
              let event = firstString(
                  in: object,
                  keys: ["hook_event_name", "hookEventName", "event", "event_name"]
              )?.lowercased(),
              event == "pre_approval_request" || event == "post_approval_response" else {
            return nil
        }
        return (event, (object["extra"] as? [String: Any]) ?? [:])
    }

    func hermesAgentApprovalSessionId(
        def: AgentHookDef,
        input: ClaudeHookParsedInput
    ) -> String? {
        guard let payload = hermesAgentApprovalPayload(def: def, input: input) else { return nil }
        return normalizedHookValue(firstString(in: payload.extra, keys: ["session_key", "sessionKey"]))
    }

    /// Hermes 0.20's TUI approval gateway omits both the top-level session id
    /// and `extra.session_key`. The cmux wrapper gives each TUI invocation a
    /// private TMPDIR containing the same active-session file consumed by its
    /// lifecycle watcher, so missing-id callbacks can still use Hermes's own
    /// conversation identity instead of mistaking the cmux surface UUID for it.
    func hermesAgentTUIActiveSessionId(
        def: AgentHookDef,
        env: [String: String]
    ) -> String? {
        guard def.name == "hermes-agent",
              env["CMUX_HERMES_TUI_HOOK_BOOTSTRAP"] == "1",
              let temporaryDirectory = normalizedHookValue(env["TMPDIR"]),
              temporaryDirectory.hasPrefix("/") else {
            return nil
        }

        let directoryURL = URL(
            fileURLWithPath: temporaryDirectory,
            isDirectory: true
        ).standardizedFileURL
        guard Self.isHermesTUIInvocationDirectoryName(directoryURL.lastPathComponent),
              Self.isRegularFileWithoutFollowingSymbolicLinks(
                  atPath: directoryURL.path,
                  expectedType: S_IFDIR
              ),
              let names = try? FileManager.default.contentsOfDirectory(atPath: directoryURL.path) else {
            return nil
        }

        let candidates = names.filter {
            $0.hasPrefix(Self.hermesTUIActiveSessionFilePrefix) && $0.hasSuffix(".json")
        }
        guard candidates.count == 1 else { return nil }

        let activeSessionURL = directoryURL.appendingPathComponent(
            candidates[0],
            isDirectory: false
        )
        guard let data = Self.readHermesTUIActiveSessionFile(atPath: activeSessionURL.path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessionId = normalizedHookValue(object["session_id"] as? String),
              Self.isValidHermesTUISessionId(sessionId) else {
            return nil
        }
        return sessionId
    }

    private static func isHermesTUIInvocationDirectoryName(_ name: String) -> Bool {
        let prefix = "cmux-hermes-tui."
        guard name.hasPrefix(prefix) else { return false }
        let suffix = name.dropFirst(prefix.count)
        return suffix.utf8.count == 6 && suffix.utf8.allSatisfy(Self.isASCIIAlphaNumeric)
    }

    private static func isValidHermesTUISessionId(_ sessionId: String) -> Bool {
        let bytes = Array(sessionId.utf8)
        guard (1...128).contains(bytes.count),
              let first = bytes.first,
              isASCIIAlphaNumeric(first) else {
            return false
        }
        return bytes.dropFirst().allSatisfy {
            isASCIIAlphaNumeric($0) || $0 == 46 || $0 == 95 || $0 == 58 || $0 == 45
        }
    }

    private static func isASCIIAlphaNumeric(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
    }

    private static func isRegularFileWithoutFollowingSymbolicLinks(
        atPath path: String,
        expectedType: mode_t
    ) -> Bool {
        var metadata = stat()
        return lstat(path, &metadata) == 0 && (metadata.st_mode & S_IFMT) == expectedType
    }

    private static func readHermesTUIActiveSessionFile(atPath path: String) -> Data? {
        guard isRegularFileWithoutFollowingSymbolicLinks(atPath: path, expectedType: S_IFREG) else {
            return nil
        }
        let descriptor = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { return nil }
        defer { _ = Darwin.close(descriptor) }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_size > 0,
              metadata.st_size <= hermesTUIActiveSessionMaximumBytes else {
            return nil
        }

        var bytes = [UInt8](repeating: 0, count: Int(metadata.st_size))
        var offset = 0
        while offset < bytes.count {
            let remaining = bytes.count - offset
            let count = bytes.withUnsafeMutableBytes { buffer -> Int in
                guard let baseAddress = buffer.baseAddress else { return -1 }
                return Darwin.read(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    remaining
                )
            }
            if count < 0, errno == EINTR {
                continue
            }
            guard count > 0 else { return nil }
            offset += count
        }
        return Data(bytes)
    }

    func isHermesAgentAutomaticApprovalObservation(
        def: AgentHookDef,
        input: ClaudeHookParsedInput
    ) -> Bool {
        guard let payload = hermesAgentApprovalPayload(def: def, input: input) else { return false }
        return firstString(in: payload.extra, keys: ["surface"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "smart"
    }

    func hermesAgentShellCommand(_ script: String) -> String {
        "sh -c \(shellQuote(script))"
    }

    func hermesAgentEvents(def: AgentHookDef) -> [HermesAgentHookConfig.Event] {
        var events = def.events.map { event in
            HermesAgentHookConfig.Event(
                name: event.agentEvent,
                command: hermesAgentShellCommand(hookCommand(for: def, event: event)),
                timeout: 5
            )
        }
        events.append(contentsOf: def.feedHookEvents.map { agentEvent in
            HermesAgentHookConfig.Event(
                name: agentEvent,
                command: hermesAgentShellCommand(feedHookCommand(for: def, agentEvent: agentEvent)),
                timeout: 120
            )
        })
        return events
    }

    func installHermesAgentHooks(_ def: AgentHookDef) throws {
        let fm = FileManager.default
        let configDir = def.resolvedConfigDir()
        let filePath = "\(configDir)/\(def.configFile)"
        let allowlistPath = "\(configDir)/shell-hooks-allowlist.json"
        let skipConfirm = ProcessInfo.processInfo.arguments.contains("--yes")
            || ProcessInfo.processInfo.arguments.contains("-y")

        let configDirectoryFileError = String.localizedStringWithFormat(
            String(
                localized: "cli.hooks.error.configDirectoryIsFile",
                defaultValue: "cmux could not create the hooks directory: a file exists at %@. Remove or rename the conflicting file, then run `cmux hooks setup` again."
            ),
            configDir
        )
        let configDirectoryCreateError = String.localizedStringWithFormat(
            String(
                localized: "cli.hooks.error.configDirectoryCreateFailed",
                defaultValue: "cmux could not create the hooks directory at %@. Check the parent directory permissions and try again."
            ),
            configDir
        )
        var isConfigDirectory: ObjCBool = false
        if fm.fileExists(atPath: configDir, isDirectory: &isConfigDirectory) {
            guard isConfigDirectory.boolValue else {
                throw CLIError(message: configDirectoryFileError)
            }
        } else {
            do {
                try fm.createDirectory(atPath: configDir, withIntermediateDirectories: true)
            } catch {
                throw CLIError(message: configDirectoryCreateError)
            }
        }

        let events = hermesAgentEvents(def: def)
        let oldString = try readAgentHookConfig(filePath: filePath, displayName: def.displayName)
        let newString = HermesAgentHookConfig.installing(events: events, in: oldString)

        if oldString != newString {
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
            try newString.write(toFile: filePath, atomically: true, encoding: .utf8)
            print("\(def.displayName) hooks installed at \(filePath)")
        } else {
            print("\(def.displayName) hooks already up to date at \(filePath)")
        }

        let updatedAllowlist = try updateHermesAgentAllowlist(atPath: allowlistPath) { oldAllowlist in
            try HermesAgentHookAllowlist.installing(events: events, in: oldAllowlist)
        }
        if updatedAllowlist {
            print("Approved \(def.displayName) cmux shell hooks in \(allowlistPath)")
        }
    }

    func uninstallHermesAgentHooks(_ def: AgentHookDef) throws {
        let fm = FileManager.default
        let configDir = def.resolvedConfigDir()
        let filePath = "\(configDir)/\(def.configFile)"
        let allowlistPath = "\(configDir)/shell-hooks-allowlist.json"
        let events = hermesAgentEvents(def: def)

        if fm.fileExists(atPath: filePath) {
            let oldString = try readAgentHookConfig(filePath: filePath, displayName: def.displayName)
            let newString = HermesAgentHookConfig.uninstalling(from: oldString)
            if oldString != newString {
                try newString.write(toFile: filePath, atomically: true, encoding: .utf8)
                print("Removed Hermes Agent cmux hooks from \(filePath)")
            } else {
                print("Removed 0 cmux hook(s) from \(filePath)")
            }
        } else {
            print("No \(def.configFile) found at \(filePath)")
        }

        guard fm.fileExists(atPath: allowlistPath) else { return }
        let updatedAllowlist = try updateHermesAgentAllowlist(atPath: allowlistPath) { oldAllowlist in
            try HermesAgentHookAllowlist.uninstalling(events: events, from: oldAllowlist)
        }
        if updatedAllowlist {
            print("Removed Hermes Agent cmux shell hook approvals from \(allowlistPath)")
        }
    }
}
