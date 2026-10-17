import Foundation

/// Secret names a repository declares.
///
/// Read from `.cmux/cloud.json` (`"env": ["NAME", …]`, or objects
/// `{"name": "NAME", "description": "…"}`) and from the devcontainer file
/// (`.devcontainer/devcontainer.json`, else `.devcontainer.json`), whose
/// `"secrets": {"NAME": {"description": "…"}}` object is the Codespaces convention.
/// Both files may contain comments and trailing commas. A name declared twice keeps
/// its first declaration; `.cmux/cloud.json` is read first. A missing or unreadable
/// file declares nothing.
/// lint:allow namespace-type: the contract's stateless reader, shared by the CLI's `secrets check` and the sheet.
public enum CloudSecretRequirements {
    static let cloudConfigPath = ".cmux/cloud.json"
    static let devcontainerPaths = [".devcontainer/devcontainer.json", ".devcontainer.json"]

    /// The files a repository declares secrets in, relative to its root, in reading order.
    public static let declaringPaths: [String] = [cloudConfigPath] + devcontainerPaths

    /// The largest declaring file read; anything bigger is not a manifest.
    public static let maxFileBytes = 256 * 1024

    public static func declared(inDirectory directory: URL) -> [CloudSecretRequirement] {
        var files: [String: String] = [:]
        for path in declaringPaths {
            if let text = fileText(directory.appendingPathComponent(path)) { files[path] = text }
        }
        return declared(files: files)
    }

    /// The same reading over file contents fetched from elsewhere (a fresh checkout on a
    /// Cloud machine), keyed by the paths in ``declaringPaths``. Other keys are ignored.
    /// These files hold names and descriptions only, never values.
    public static func declared(files: [String: String]) -> [CloudSecretRequirement] {
        var requirements: [CloudSecretRequirement] = []
        var seen: Set<String> = []
        func add(_ requirement: CloudSecretRequirement) {
            guard !requirement.name.isEmpty,
                  (try? CloudSecretInput.validateNameSyntax(requirement.name)) != nil,
                  !CloudSecretInput.isReservedName(requirement.name),
                  seen.insert(requirement.name).inserted else { return }
            requirements.append(requirement)
        }
        if let object = files[cloudConfigPath].flatMap({ CloudSecretJSONC(text: $0).object() }) {
            for requirement in cloudConfigRequirements(object) { add(requirement) }
        }
        for path in devcontainerPaths {
            guard let object = files[path].flatMap({ CloudSecretJSONC(text: $0).object() }) else { continue }
            for requirement in devcontainerRequirements(object, source: path) { add(requirement) }
            break
        }
        return requirements
    }

    /// The declared names no record covers for a target. A record covers a name when its
    /// scope is ``CloudSecretScope/all``, a project in `projectKeys`, or the machine
    /// `machineID`, which are the scopes that machine's effective set draws from. Declaration
    /// order is kept.
    public static func missing(
        _ requirements: [CloudSecretRequirement],
        records: [CloudSecretRecord],
        projectKeys: [String],
        machineID: String?
    ) -> [CloudSecretRequirement] {
        let projects = Set(projectKeys)
        let covered = Set(records.filter { record in
            // Reserved names stay in the vault so legacy entries can be
            // removed, but effectiveEntries never delivers them to a machine.
            // They therefore cannot satisfy a checkout requirement.
            guard !CloudSecretInput.isReservedName(record.name) else { return false }
            switch record.scope {
            case .all: return true
            case .project(let key): return projects.contains(key)
            case .machine(let id): return id == machineID
            }
        }.map(\.name))
        return requirements.filter { !covered.contains($0.name) }
    }

    static func cloudConfigRequirements(_ object: [String: Any]) -> [CloudSecretRequirement] {
        guard let env = object["env"] as? [Any] else { return [] }
        return env.compactMap { item -> CloudSecretRequirement? in
            if let name = item as? String {
                return CloudSecretRequirement(name: name.trimmingCharacters(in: .whitespaces), description: nil, source: cloudConfigPath)
            }
            if let entry = item as? [String: Any], let name = entry["name"] as? String {
                return CloudSecretRequirement(
                    name: name.trimmingCharacters(in: .whitespaces),
                    description: nonEmpty(entry["description"] as? String),
                    source: cloudConfigPath
                )
            }
            return nil
        }
    }

    static func devcontainerRequirements(_ object: [String: Any], source: String) -> [CloudSecretRequirement] {
        guard let secrets = object["secrets"] as? [String: Any] else { return [] }
        return secrets.keys.sorted().map { name in
            let description = (secrets[name] as? [String: Any])?["description"] as? String
            return CloudSecretRequirement(name: name, description: nonEmpty(description), source: source)
        }
    }

    private static func fileText(_ url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              (values.fileSize ?? 0) <= maxFileBytes,
              let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
