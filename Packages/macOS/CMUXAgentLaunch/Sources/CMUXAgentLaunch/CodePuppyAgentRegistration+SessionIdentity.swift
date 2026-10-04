import Foundation

extension CodePuppyAgentRegistration {
    /// Returns Code Puppy's autosave directory using its explicit-XDG cache convention.
    /// - Parameters:
    ///   - homeDirectory: The agent account's home directory.
    ///   - environment: The launch environment, including any XDG cache override.
    /// - Returns: The directory containing persisted Code Puppy sessions.
    public func autosaveDirectory(homeDirectory: String, environment: [String: String]) -> URL {
        let base: URL
        if let xdg = environment["XDG_CACHE_HOME"], !xdg.isEmpty {
            base = URL(fileURLWithPath: xdg).appendingPathComponent("code_puppy")
        } else {
            base = URL(fileURLWithPath: homeDirectory).appendingPathComponent(".code_puppy")
        }
        return base.appendingPathComponent("autosaves")
    }

    /// Resolves hook identity only when it names a durable autosave, never a routing/run UUID.
    ///
    /// Older integrations emit a bare autosave suffix; named sessions must not be blindly
    /// prefixed. Native hooks in some Code Puppy releases emit unrelated per-run UUIDs.
    /// - Parameters:
    ///   - hookID: The untrusted identity supplied by a hook.
    ///   - homeDirectory: The agent account's home directory.
    ///   - environment: The agent's launch environment.
    ///   - fileManager: The filesystem used to check durable evidence.
    /// - Returns: The stored name accepted by `--resume`, or nil without authoritative evidence.
    public func resumableHookSessionID(
        _ hookID: String?, homeDirectory: String, environment: [String: String],
        fileManager: FileManager
    ) -> String? {
        guard let name = hookID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty, name != "codepuppy-session",
              name != ".", name != "..", !name.contains("/"), !name.contains("\\"),
              !name.contains("\u{0}") else { return nil }
        let directory = autosaveDirectory(homeDirectory: homeDirectory, environment: environment)
        for candidate in [name, "auto_session_" + name] {
            for suffix in [".pkl", ".json"] {
                var isDirectory: ObjCBool = false
                if fileManager.fileExists(
                    atPath: directory.appendingPathComponent(candidate + suffix).path,
                    isDirectory: &isDirectory
                ), !isDirectory.boolValue { return candidate }
            }
        }
        return nil
    }
}
