import Foundation

/// One skill `/` lists in the Chief composer: what the person types, what it
/// does and where it lives. The Mac's Chief host sends the list in
/// `chief.engine.get` (`offered.skills`, optchat-chief engine_control.rs), so
/// the phone lists what that host runs when the message arrives
/// (slash_skills.rs). The Mac's own composer lists the same folders
/// (MessagesLab `SlashSkillCatalog`).
public struct ChiefSlashSkill: Codable, Sendable, Equatable, Hashable {
    /// The command without its slash (`emil-prototype`, `vercel:ai-sdk`).
    public var name: String
    /// The skill's description, on one line.
    public var description: String
    /// `chief`, `claude` or `plugin:<plugin>`.
    public var source: String

    public init(name: String, description: String, source: String) {
        self.name = name
        self.description = description
        self.source = source
    }

    /// The row's source label: Chief, Claude, or the plugin's name.
    public var sourceLabel: String {
        switch source {
        case "chief": String(localized: "mobile.chief.slash.source.chief", defaultValue: "Chief", bundle: .module)
        case "claude": String(localized: "mobile.chief.slash.source.claude", defaultValue: "Claude", bundle: .module)
        default: source.hasPrefix("plugin:") ? String(source.dropFirst("plugin:".count)) : source
        }
    }
}

/// A backend that lists its own skills (the mock Chief); the Mac's Chief
/// lists them through its engine report instead.
public protocol ChiefSlashSkillSource: AnyObject {
    var slashSkills: [ChiefSlashSkill] { get }
}

/// What the composer's `/` list can show now.
public enum ChiefSlashSkillList: Equatable, Sendable {
    /// No list: a Chief that cannot name its skills here (the Cloud Chief, or
    /// a Mac whose Chief is older than the list).
    case none
    /// The list is on its way: the rows say so instead of showing nothing.
    case loading
    /// The Mac's Chief did not answer; the row says the skills could not load.
    case failed
    case loaded([ChiefSlashSkill])
}

/// The `/` list of a draft: open while the field starts with `/` and the
/// caret is in the command. Matching follows the Mac's (MessagesLab
/// `SlashSkillMenu`): names that start with the query first, then names
/// with a word (after `-`, `_`, `:` or `.`) that starts with it, then names
/// that hold it, then descriptions that hold it; each group keeps the list's
/// order.
public struct ChiefSlashMenu: Equatable, Sendable {
    /// The words typed after the slash.
    public let query: String
    /// The UTF-16 length of the command, slash included (what a pick replaces).
    public let commandLength: Int

    /// The menu of `text` with the caret at UTF-16 offset `caret`; nil when
    /// the field holds no command there (no leading slash, a path such as
    /// `/tmp/x`, or the caret past the command).
    public init?(text: String, caret: Int) {
        let ns = text as NSString
        guard ns.length > 0, ns.character(at: 0) == 0x2F else { return nil }
        let space = ns.rangeOfCharacter(from: .whitespacesAndNewlines)
        let end = space.location == NSNotFound ? ns.length : space.location
        guard caret >= 1, caret <= end else { return nil }
        let query = ns.substring(with: NSRange(location: 1, length: end - 1))
        guard !query.contains("/") else { return nil }
        self.query = query
        commandLength = end
    }

    /// `skills` that match the query, best first.
    public func matches(_ skills: [ChiefSlashSkill]) -> [ChiefSlashSkill] {
        let q = query.lowercased()
        guard !q.isEmpty else { return skills }
        var prefix: [ChiefSlashSkill] = [], word: [ChiefSlashSkill] = []
        var inName: [ChiefSlashSkill] = [], inSummary: [ChiefSlashSkill] = []
        for skill in skills {
            let name = skill.name.lowercased()
            if name.hasPrefix(q) {
                prefix.append(skill)
            } else if name.split(whereSeparator: { "-_:.".contains($0) }).contains(where: { $0.hasPrefix(q) }) {
                word.append(skill)
            } else if name.contains(q) {
                inName.append(skill)
            } else if skill.description.lowercased().contains(q) {
                inSummary.append(skill)
            }
        }
        return prefix + word + inName + inSummary
    }

    /// `text` with the command replaced by `skill`'s, a space after it, and
    /// the caret's UTF-16 offset after that space.
    public func applied(_ skill: ChiefSlashSkill, to text: String) -> (text: String, caret: Int) {
        let ns = text as NSString
        let rest = ns.substring(from: min(commandLength, ns.length))
        let command = "/" + skill.name
        let joined = rest.first?.isWhitespace == true ? command + rest : command + " " + rest
        return (joined, (command as NSString).length + 1)
    }
}

extension ChiefSession {
    /// What `/` lists in this Chief's composer now: the mock's own skills,
    /// else the Mac Chief's engine report (the kept one while a read runs).
    public var slashSkillList: ChiefSlashSkillList {
        if let source = backend as? any ChiefSlashSkillSource { return .loaded(source.slashSkills) }
        if let skills = engineReport?.offered.skills { return .loaded(skills) }
        guard control != nil else { return .none }
        // A current report without the list: the Mac's Chief is older.
        if engineReport != nil, engineReportIsCurrent { return .none }
        return engineProblem == nil ? .loading : .failed
    }

    /// `/` was typed: reads the engine report when the list is not here yet
    /// (one read at a time; the list redraws when it lands).
    public func loadSlashSkillsIfNeeded() {
        switch slashSkillList {
        case .loading, .failed:
            guard !slashSkillsLoading else { return }
            slashSkillsLoading = true
            // task-owner: this session; one engine read, then it ends
            Task { @MainActor [weak self] in
                await self?.refreshEngine()
                self?.slashSkillsLoading = false
            }
        case .none, .loaded:
            return
        }
    }
}
