// cmux: a skill the Chief composer's `/` menu lists (plans: Native/OptChat/optchat-chief/src/slash_skills.rs). Not a vendored file.
import Foundation

/// One skill `/` offers in a Chief chat: what the person types, what it does and where it lives.
public struct SlashSkill: Equatable, Sendable {
    /// Where a skill comes from, in the order a name is looked up (the first source that has a name wins).
    public enum Source: Equatable, Sendable {
        /// The Chief's own or shared skills (`$MUX_HOME/skills`, `~/.cmux/chief/skills`).
        case chief
        /// The person's Claude Code skills (`~/.claude/skills`).
        case claude
        /// A skill of an installed Claude Code plugin, by the plugin's name.
        case plugin(String)
    }

    /// The command without its slash (`emil-prototype`, `vercel:ai-sdk`).
    public let name: String
    /// The front matter's description, on one line.
    public let summary: String
    /// Where the skill comes from.
    public let source: Source

    /// - Parameters:
    ///   - name: The command without its slash.
    ///   - summary: The skill's description.
    ///   - source: Where it comes from.
    public init(name: String, summary: String, source: Source) {
        self.name = name
        self.summary = summary
        self.source = source
    }

    /// What the field holds once the skill is picked: the command and a space for its input.
    var completion: String { "/\(name) " }
}
