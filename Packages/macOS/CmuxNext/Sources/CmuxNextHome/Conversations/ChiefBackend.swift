public import Foundation

/// One official engine a Chief runs on: the acpmux harness id the brain is
/// given (`chief.engine.set` `harness`, `chief.profile.create` `harness`) and
/// the name the app shows for it. New Chief offers these, the Chief Settings
/// harness picker titles its items with them, and a Home row of a Chief that
/// runs on another engine than the default shows its name as a badge.
public nonisolated struct ChiefBackend: Hashable, Sendable, Identifiable {
    /// The acpmux harness id (`claude`, `codex`, `unii`).
    public let id: String
    /// Where New Chief makes a Chief on this engine: false, the signed-in
    /// account's cloud Chief (`chief.create`); true, a Chief of this Mac's Chief
    /// owner (`chief.profile.create` with `harness`). UniiChat's sign-in
    /// (`unii login`) lives on this Mac, so its Chiefs are this Mac's. A cloud
    /// Chief's brain is not placed when it is made, so a Codex Chief is made
    /// on this Mac too, where its engine is set in the same request.
    public let createsOnThisMac: Bool

    /// Claude: the brain's default engine, and New Chief's first choice.
    public static let claude = ChiefBackend(id: "claude", createsOnThisMac: false)
    /// Codex.
    public static let codex = ChiefBackend(id: "codex", createsOnThisMac: true)
    /// Muse Code (Meta) through the cmux-muse-acp adapter (acpmux harness `muse`), on this
    /// Mac's Muse sign-in (`muse login`).
    public static let muse = ChiefBackend(id: "muse", createsOnThisMac: true)
    /// UniiChat: acpmux's built-in `unii` harness (`acpmux uniichat-agent`), on the person's UniiChat account.
    public static let unii = ChiefBackend(id: "unii", createsOnThisMac: true)
    /// Every official engine, in the order the pickers offer them.
    public static let official: [ChiefBackend] = [.claude, .codex, .muse, .unii]

    /// The engine whose harness id is `id`; nil for an id that is not an official engine.
    public init?(id: String) {
        guard let backend = Self.official.first(where: { $0.id == id }) else { return nil }
        self = backend
    }

    private init(id: String, createsOnThisMac: Bool) {
        self.id = id
        self.createsOnThisMac = createsOnThisMac
    }

    /// Whether this is the engine a Chief runs on when nothing else is chosen (Claude).
    public var isDefault: Bool { self == .claude }

    /// The name the app shows for this engine.
    public var title: String {
        switch id {
        case "codex": String(localized: "home.chief.backend.codex", defaultValue: "Codex", bundle: .module)
        case "muse": String(localized: "home.chief.backend.muse", defaultValue: "Muse Code", bundle: .module)
        case "unii": String(localized: "home.chief.backend.unii", defaultValue: "UniiChat", bundle: .module)
        default: String(localized: "home.chief.backend.claude", defaultValue: "Claude", bundle: .module)
        }
    }

    /// One line under a picker that has this engine chosen, or nil when it needs none.
    public var hint: String? {
        switch id {
        case "unii":
            String(localized: "home.chief.backend.uniiHint",
                   defaultValue: "Runs on your UniiChat account. Sign in first with `unii login`.", bundle: .module)
        case "muse":
            String(localized: "home.chief.backend.museHint",
                   defaultValue: "Runs on this Mac with your Muse sign-in (`muse login`) through the muse-acp adapter.",
                   bundle: .module)
        case "codex":
            String(localized: "home.chief.backend.codexHint",
                   defaultValue: "Runs on this Mac with your Codex sign-in.", bundle: .module)
        default: nil
        }
    }

    /// The name to show for harness `id`: an official engine's title, else the id made readable
    /// (``Swift/String/chiefHarnessName``: `claude-cr` → "Claude (CodeRouter)"), never the raw id.
    public static func title(for id: String) -> String {
        ChiefBackend(id: id)?.title ?? id.chiefHarnessName
    }

    /// The badge a Home row shows for a Chief whose effective harness is `harness`: nil for
    /// the default engine (no choice, `default`, or a Claude route such as `claude-cr`),
    /// else the engine's name (an unknown id made readable).
    public static func badge(for harness: String?) -> String? {
        guard let harness = harness?.trimmingCharacters(in: .whitespacesAndNewlines), !harness.isEmpty,
              harness != "default", !harness.hasPrefix(ChiefBackend.claude.id) else { return nil }
        return title(for: harness)
    }
}
