import Foundation

/// Credentials in a message the person is about to send (cmux issue 26412): the shapes providers
/// give their API keys and tokens. A send that holds one is held, and the host offers to move it
/// into the Credential Vault, so it never reaches the transcript, the model or a log. Shapes only,
/// never entropy guesses: ordinary text (hashes, ids, URLs) must not trip it.
public struct HomeSecretScan: Sendable {
    /// One credential found: its text and the vault name it would go under.
    public struct Finding: Equatable, Sendable {
        public var value: String
        public var suggestedName: String

        public init(value: String, suggestedName: String) {
            self.value = value
            self.suggestedName = suggestedName
        }
    }

    /// A provider's key shape and the env name its programs read.
    private struct Shape {
        let regex: NSRegularExpression
        let name: String
    }

    /// The most specific first: `sk-ant-` before `sk-`.
    private static let shapes: [Shape] = [
        ("sk-ant-[A-Za-z0-9_-]{20,}", "ANTHROPIC_API_KEY"),
        ("sk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{20,}", "OPENAI_API_KEY"),
        ("github_pat_[A-Za-z0-9_]{22,}", "GH_TOKEN"),
        ("gh[pousr]_[A-Za-z0-9]{30,}", "GH_TOKEN"),
        ("glpat-[A-Za-z0-9_-]{20,}", "GITLAB_TOKEN"),
        ("xox[abprs]-[A-Za-z0-9-]{10,}", "SLACK_TOKEN"),
        ("(?:sk|rk)_live_[A-Za-z0-9]{20,}", "STRIPE_API_KEY"),
        ("AKIA[0-9A-Z]{16}", "AWS_ACCESS_KEY_ID"),
        ("AIza[0-9A-Za-z_-]{35}", "GOOGLE_API_KEY"),
        ("hf_[A-Za-z0-9]{30,}", "HF_TOKEN"),
        ("npm_[A-Za-z0-9]{36}", "NPM_TOKEN"),
        ("vercel_[A-Za-z0-9]{24,}", "VERCEL_TOKEN"),
    ].compactMap { pattern, name in
        // A shape starts and ends at a word edge, so it never matches inside a longer word.
        (try? NSRegularExpression(pattern: "(?<![A-Za-z0-9_-])" + pattern + "(?![A-Za-z0-9_-])")).map { Shape(regex: $0, name: name) }
    }

    public init() {}

    /// Every credential in `text`, in order, each once.
    public func findings(in text: String) -> [Finding] {
        guard text.utf8.count >= 16 else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        let ns = text as NSString
        var found: [(NSRange, Finding)] = []
        for shape in Self.shapes {
            for match in shape.regex.matches(in: text, range: range) {
                guard !found.contains(where: { NSIntersectionRange($0.0, match.range).length > 0 }) else { continue }
                found.append((match.range, Finding(value: ns.substring(with: match.range), suggestedName: shape.name)))
            }
        }
        var seen = Set<String>()
        return found.sorted { $0.0.location < $1.0.location }.map(\.1).filter { seen.insert($0.value).inserted }
    }

    /// `text` with each occurrence of `value` replaced by `[vault:NAME]`.
    public static func redacted(_ text: String, value: String, name: String) -> String {
        text.replacingOccurrences(of: value, with: "[vault:\(name)]")
    }
}
