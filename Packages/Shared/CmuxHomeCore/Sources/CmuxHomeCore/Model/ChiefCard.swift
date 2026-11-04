public import Foundation

/// A Chief's `card` part (cmux issue 25830, tagged by `kind`): a live browser or computer step with
/// its screenshot, a Secure Store sign-in request, or next-step suggestions. Only an agent posts
/// one; a person never sends it. A card of a kind this build does not know does not decode (its
/// part then shows as text).
public struct ChiefCard: Hashable, Sendable, Codable {
    public enum Kind: String, Hashable, Sendable, Codable { case browser, signIn = "sign_in", nextSteps = "next_steps" }
    public enum Surface: String, Hashable, Sendable, Codable { case browser, computer }

    /// What a browser card's "Open browser" opens.
    public enum Target: Hashable, Sendable {
        /// The browser column right of the Home chat on the Mac running the Chief.
        case browserRight
        /// A cmux Cloud machine's desktop.
        case machine(String)

        public init?(wire: String) {
            if wire == "browser:right" { self = .browserRight; return }
            let prefix = "machine:"
            guard wire.hasPrefix(prefix) else { return nil }
            let id = String(wire.dropFirst(prefix.count))
            guard (1...128).contains(id.count),
                  id.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "_" || $0 == "-" })
            else { return nil }
            self = .machine(id)
        }

        public var wire: String {
            switch self {
            case .browserRight: "browser:right"
            case .machine(let id): "machine:\(id)"
            }
        }
    }

    /// A browser card's screenshot: an attachment record of the conversation, fetched by its hash.
    public struct Image: Hashable, Sendable, Codable {
        public var hash: String
        public var mimeType: String
        public var byteCount: Int
        public var width: Int?
        public var height: Int?

        public init(hash: String, mimeType: String, byteCount: Int, width: Int? = nil, height: Int? = nil) {
            self.hash = hash
            self.mimeType = mimeType
            self.byteCount = byteCount
            self.width = width
            self.height = height
        }

        enum CodingKeys: String, CodingKey {
            case hash, width, height
            case mimeType = "mime_type"
            case byteCount = "byte_count"
        }

        /// The image as an attachment ref (HomeMedia and the stores fetch it by hash).
        public var attachmentRef: AttachmentRef {
            AttachmentRef(hash: hash, name: "card-image", mimeType: mimeType, byteCount: byteCount, width: width, height: height)
        }
    }

    public var kind: Kind
    // browser
    public var surface: Surface?
    public var step: String?
    public var live: Bool
    public var target: String?
    public var url: String?
    public var image: Image?
    // sign_in
    public var site: String?
    // next_steps
    public var choices: [String]

    public init(kind: Kind, surface: Surface? = nil, step: String? = nil, live: Bool = false, target: String? = nil,
                url: String? = nil, image: Image? = nil, site: String? = nil, choices: [String] = []) {
        self.kind = kind
        self.surface = surface
        self.step = step
        self.live = live
        self.target = target
        self.url = url
        self.image = image
        self.site = site
        self.choices = choices
    }

    public static func browser(surface: Surface = .browser, step: String, live: Bool = false, target: String? = nil,
                               url: String? = nil, image: Image? = nil) -> ChiefCard {
        ChiefCard(kind: .browser, surface: surface, step: step, live: live, target: target, url: url, image: image)
    }

    public static func signIn(site: String, url: String? = nil) -> ChiefCard {
        ChiefCard(kind: .signIn, url: url, site: site)
    }

    public static func nextSteps(_ choices: [String]) -> ChiefCard {
        ChiefCard(kind: .nextSteps, choices: choices)
    }

    enum CodingKeys: String, CodingKey {
        case type, kind, surface, step, live, target, url, image, site, choices
    }

    /// The owner's part (`{"type":"card","kind":...}`). The owner validated it; this reads only
    /// what each kind needs and refuses a card without it.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(Kind.self, forKey: .kind)
        surface = try c.decodeIfPresent(Surface.self, forKey: .surface)
        step = try c.decodeIfPresent(String.self, forKey: .step)
        live = try c.decodeIfPresent(Bool.self, forKey: .live) ?? false
        target = try c.decodeIfPresent(String.self, forKey: .target)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        image = try? c.decodeIfPresent(Image.self, forKey: .image)
        site = try c.decodeIfPresent(String.self, forKey: .site)
        choices = try c.decodeIfPresent([String].self, forKey: .choices) ?? []
        switch kind {
        case .browser:
            guard let step, !step.isEmpty else {
                throw DecodingError.dataCorruptedError(forKey: .step, in: c, debugDescription: "a browser card has a step")
            }
            if surface == nil { surface = .browser }
        case .signIn:
            guard let site, !site.isEmpty else {
                throw DecodingError.dataCorruptedError(forKey: .site, in: c, debugDescription: "a sign_in card has a site")
            }
        case .nextSteps:
            choices = choices.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            guard !choices.isEmpty else {
                throw DecodingError.dataCorruptedError(forKey: .choices, in: c, debugDescription: "next_steps has choices")
            }
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("card", forKey: .type)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(surface, forKey: .surface)
        try c.encodeIfPresent(step, forKey: .step)
        if kind == .browser { try c.encode(live, forKey: .live) }
        try c.encodeIfPresent(target, forKey: .target)
        try c.encodeIfPresent(url, forKey: .url)
        try c.encodeIfPresent(image, forKey: .image)
        try c.encodeIfPresent(site, forKey: .site)
        if !choices.isEmpty { try c.encode(choices, forKey: .choices) }
    }

    /// The parsed `target` (nil: no "Open browser" button).
    public var openTarget: Target? { target.flatMap(Target.init(wire:)) }

    /// The card's text for readers without cards (the wire spec's fallback): previews, search, copy.
    public var plainText: String {
        switch kind {
        case .browser: "\(surface == .computer ? "Computer" : "Browser"): \(step ?? "")"
        case .signIn: "Secure Store: sign in to \(site ?? "")"
        case .nextSteps: choices.map { "→ \($0)" }.joined(separator: "\n")
        }
    }

    /// The choices a later message from a person already picked: a chip is chosen when a person
    /// message after its card says exactly its text (derived; no op records it).
    public static func chosen(_ choices: [String], laterPersonTexts: some Sequence<String>) -> Set<String> {
        let wanted = Set(choices)
        var picked: Set<String> = []
        for text in laterPersonTexts {
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if wanted.contains(text) { picked.insert(text) }
        }
        return picked
    }
}
