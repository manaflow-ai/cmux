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

    public static func declared(inDirectory directory: URL) -> [CloudSecretRequirement] {
        var requirements: [CloudSecretRequirement] = []
        var seen: Set<String> = []
        func add(_ requirement: CloudSecretRequirement) {
            guard !requirement.name.isEmpty, seen.insert(requirement.name).inserted else { return }
            requirements.append(requirement)
        }
        if let object = jsonObject(directory.appendingPathComponent(cloudConfigPath)) {
            for requirement in cloudConfigRequirements(object) { add(requirement) }
        }
        for path in devcontainerPaths {
            guard let object = jsonObject(directory.appendingPathComponent(path)) else { continue }
            for requirement in devcontainerRequirements(object, source: path) { add(requirement) }
            break
        }
        return requirements
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

    private static func jsonObject(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return nil }
        return CloudSecretJSONC(text: text).object()
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
