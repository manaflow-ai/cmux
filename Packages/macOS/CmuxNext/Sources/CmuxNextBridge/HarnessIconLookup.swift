import CmuxAgentBrands
import CmuxNextDaemon
public import CmuxNextSidebar
public import CmuxNextTabs

/// Each harness's own icon, drawn for the native surfaces (user 12922): what
/// ``HarnessIconArtwork`` rendered from one `_acpmux/harnesses` reply. A value the tab strip and
/// sidebar mappings take, so they stay pure; its images keep their identity until the list
/// changes, so a snapshot that draws the same icon never redraws it.
public struct HarnessIconLookup: Equatable, Sendable {
    /// No icons (the list is not read yet): every surface keeps its brand mark or kind icon.
    public static let none = HarnessIconLookup()

    /// One harness's (or one chat's own) drawn icon.
    enum Art: Equatable, Sendable {
        /// An agent mark id: the surfaces' own brand drawing.
        case brand(String)
        /// An SF Symbol name.
        case symbol(String)
        /// A full-color image (an emoji, a PNG or SVG, a monogram).
        case image(TabImage, SidebarFavicon)
    }

    var art: [String: (art: Art, isOwn: Bool)] = [:]
    /// Draws a chat's own icon once (``HarnessIconArtwork``'s chat icons, ``chatArt(_:)``); in
    /// ``none`` no chat icon draws.
    var drawChat: @MainActor @Sendable (HarnessIconSpec?) -> Art? = { _ in nil }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.art.count == rhs.art.count && lhs.art.allSatisfy { key, value in rhs.art[key].map { $0.art == value.art && $0.isOwn == value.isOwn } ?? false }
    }

    /// The drawn icon a chat gave itself (`acpmux icon @ 🥭`), drawn before its harness's.
    func chatArt(_ spec: HarnessIconSpec?) -> Art? {
        drawChat(spec)
    }

    /// The icon to draw for `harness` in place of what its id suggests: the profile's own icon,
    /// or acpmux's pick for a harness whose id names no known mark.
    func custom(for harness: String?) -> Art? {
        guard let harness, let entry = art[harness] else { return nil }
        return entry.isOwn || AgentBrandCatalog.brand(for: harness) == nil ? entry.art : nil
    }

    /// The tab strip's icon for a chat on `harness`, or nil to keep the usual one.
    func tabIcon(for harness: String?) -> TabIcon? {
        Self.tabIcon(custom(for: harness))
    }

    /// The tab strip's icon for drawn icon `art`, or nil when there is none.
    static func tabIcon(_ art: Art?) -> TabIcon? {
        switch art {
        case .brand(let brand)?: .agentMark(brand)
        case .symbol(let name)?: .symbol(name)
        case .image(let image, _)?: .image(image)
        case nil: nil
        }
    }
}
