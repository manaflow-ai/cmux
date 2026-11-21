// cmux: the skills a Chief chat's `/` lists, read from the folders the Chief host reads
// (Native/OptChat/optchat-chief/src/slash_skills.rs `catalog`). Not a vendored file.
import Foundation

/// The skill folders of one Chief and the person's Claude Code home; ``load()`` lists their skills.
///
/// The order matches the host's: the Chief's own skills, the shared Chief skills, the person's
/// Claude Code skills, then each installed plugin's skills as `<plugin>:<skill>`. A name is listed
/// once (the first folder that has it wins), and the list is sorted within each source.
///
/// ```swift
/// let catalog = SlashSkillCatalog(chiefHome: muxHome, claudeHome: home.appending(path: ".claude"))
/// let skills = await Task.detached { catalog.load() }.value
/// ```
public struct SlashSkillCatalog: Equatable, Sendable {
    /// The Chief's home (`$MUX_HOME`); its own skills are `skills/`, the shared ones its parent's `skills/`.
    public let chiefHome: URL
    /// The person's Claude Code home (`~/.claude`).
    public let claudeHome: URL

    /// - Parameters:
    ///   - chiefHome: The Chief's `$MUX_HOME`.
    ///   - claudeHome: The person's Claude Code home.
    public init(chiefHome: URL, claudeHome: URL) {
        self.chiefHome = chiefHome
        self.claudeHome = claudeHome
    }

    /// Every listed skill, in lookup order. Reads the disk: call it off the main thread.
    public func load() -> [SlashSkill] {
        var out: [SlashSkill] = []
        var seen = Set<String>()
        func add(_ skills: [SlashSkill]) {
            for skill in skills where seen.insert(skill.name).inserted { out.append(skill) }
        }
        // Own over shared by name, then one sorted list (the host's skills::load).
        var chief: [String: SlashSkill] = [:]
        for dir in [chiefHome.deletingLastPathComponent().appending(path: "skills"), chiefHome.appending(path: "skills")] {
            for skill in folder(dir, source: .chief) { chief[skill.name] = skill }
        }
        add(chief.values.sorted { $0.name < $1.name })
        add(folder(claudeHome.appending(path: "skills"), source: .claude))
        for (plugin, path) in installedPlugins() {
            add(folder(path.appending(path: "skills"), source: .plugin(plugin), prefix: "\(plugin):"))
        }
        return out
    }

    /// The skills under `dir` (`<dir>/<folder>/SKILL.md` with a name and a description), sorted by name.
    private func folder(_ dir: URL, source: SlashSkill.Source, prefix: String = "") -> [SlashSkill] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.compactMap { name -> SlashSkill? in
            let file = dir.appending(path: name).appending(path: "SKILL.md")
            guard let text = try? String(contentsOf: file, encoding: .utf8),
                  let (skill, summary) = skillFrontMatter(text) else { return nil }
            return SlashSkill(name: prefix + skill, summary: summary, source: source)
        }
        .sorted { $0.name < $1.name }
    }

    /// The installed plugins as (name, install path), from `plugins/installed_plugins.json`, each path once.
    private func installedPlugins() -> [(String, URL)] {
        let file = claudeHome.appending(path: "plugins").appending(path: "installed_plugins.json")
        guard let data = try? Data(contentsOf: file),
              let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plugins = doc["plugins"] as? [String: Any] else { return [] }
        var out: [(String, URL)] = []
        for (key, installs) in plugins {
            let name = String(key.split(separator: "@").first ?? Substring(key))
            for install in installs as? [[String: Any]] ?? [] {
                guard let path = install["installPath"] as? String else { continue }
                let url = URL(fileURLWithPath: path)
                if !out.contains(where: { $0.1 == url }) { out.append((name, url)) }
            }
        }
        return out.sorted { ($0.0, $0.1.path) < ($1.0, $1.1.path) }
    }
}

/// `name` and `description` of a SKILL.md's front matter (`---` lines), nil when either is missing.
func skillFrontMatter(_ text: String) -> (String, String)? {
    guard text.hasPrefix("---") else { return nil }
    let body = text.dropFirst(3)
    guard let end = body.range(of: "\n---") else { return nil }
    var name: String?, description: String?
    for line in body.prefix(upTo: end.lowerBound).split(separator: "\n", omittingEmptySubsequences: false) {
        func value(_ key: String) -> String? {
            guard line.hasPrefix(key) else { return nil }
            return line.dropFirst(key.count).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        if let v = value("name:") { name = v } else if let v = value("description:") { description = v }
    }
    guard let name, !name.isEmpty, let description, !description.isEmpty else { return nil }
    return (name, description)
}
