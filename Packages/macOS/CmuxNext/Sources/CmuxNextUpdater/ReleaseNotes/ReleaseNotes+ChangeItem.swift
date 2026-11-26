public import Foundation

nonisolated extension ReleaseNotes {
    /// One change of a build (UPDATE-CARD "What's changed"): its title, its
    /// author when the notes name one, and its pull request.
    public struct ChangeItem: Codable, Equatable, Sendable {
        public var title: String
        public var author: String?
        /// One plain-language sentence extracted from the PR body at release time.
        public var description: String?
        /// The pull request number in manaflow-ai/cmux.
        public var pr: Int?
        /// True when every file the commit touches is CI or tooling (release-notes.py
        /// `tooling_only`): the page and the Updated card leave it out whatever its subject says.
        /// Nil in notes published before the flag.
        public var isInternal: Bool?
        /// The product area the PR touches (`sidebar`, `terminal`, ...), when the notes name one.
        /// Nil in notes published before the field: "What's in this build" files it under Other.
        public var area: String?
        /// The PR's page as the notes give it (`url`); nil falls back to the manaflow-ai/cmux pull page (``url``).
        public var link: URL?

        enum CodingKeys: String, CodingKey {
            case title, author, description, pr, area
            case isInternal = "internal"
            case link = "url"
        }

        public init(title: String, author: String? = nil, description: String? = nil, pr: Int? = nil, isInternal: Bool? = nil,
                    area: String? = nil, link: URL? = nil) {
            self.title = title
            self.author = author
            self.description = description
            self.pr = pr
            self.isInternal = isInternal
            self.area = area
            self.link = link
        }

        /// Tolerant of the newer optional fields: a bad `url` or `area` drops that field, never the notes.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            title = try container.decode(String.self, forKey: .title)
            author = try container.decodeIfPresent(String.self, forKey: .author)
            description = try container.decodeIfPresent(String.self, forKey: .description)
            pr = try container.decodeIfPresent(Int.self, forKey: .pr)
            isInternal = try container.decodeIfPresent(Bool.self, forKey: .isInternal)
            let area = (try? container.decodeIfPresent(String.self, forKey: .area))?.trimmingCharacters(in: .whitespaces)
            self.area = area?.isEmpty == false ? area : nil
            link = (try? container.decodeIfPresent(String.self, forKey: .link)).flatMap { URL(string: $0) }
                .flatMap { $0.scheme == "https" ? $0 : nil }
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

        /// The pull request page: the notes' own `url`, else the manaflow-ai/cmux pull page; nil without either.
        public var url: URL? {
            link ?? pr.flatMap { URL(string: "https://github.com/manaflow-ai/cmux/pull/\($0)") }
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
