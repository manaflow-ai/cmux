public import Foundation

nonisolated extension ReleaseNotes {
    /// One change of a build (UPDATE-CARD "What's changed"): its title, its
    /// author when the notes name one, and its pull request.
    public struct ChangeItem: Codable, Equatable, Sendable {
        public var title: String
        public var author: String?
        /// The pull request number in manaflow-ai/cmux.
        public var pr: Int?

        public init(title: String, author: String? = nil, pr: Int? = nil) {
            self.title = title
            self.author = author
            self.pr = pr
        }

        /// A commit subject: "Title (#1234)" gives the title and PR 1234;
        /// a subject without that suffix is the whole title (no author).
        public init(subject: String) {
            let text = subject.trimmingCharacters(in: .whitespaces)
            guard text.hasSuffix(")"), let open = text.range(of: "(#", options: .backwards) else {
                self.init(title: text)
                return
            }
            let digits = text[open.upperBound..<text.index(before: text.endIndex)]
            guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(digits) else {
                self.init(title: text)
                return
            }
            let title = text[..<open.lowerBound].trimmingCharacters(in: .whitespaces)
            self.init(title: title.isEmpty ? text : title, pr: number)
        }

        /// The pull request page, or nil without a PR number.
        public var url: URL? {
            pr.flatMap { URL(string: "https://github.com/manaflow-ai/cmux/pull/\($0)") }
        }

        /// The PR's short label ("#1234"), or nil.
        public var prLabel: String? { pr.map { "#\($0)" } }
    }

    /// The build's changes, newest first: the structured items when the
    /// notes carry them, else one item per commit subject.
    public var changeItems: [ChangeItem] {
        items ?? changes.map(ChangeItem.init(subject:))
    }
}
