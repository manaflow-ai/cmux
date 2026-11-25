#if os(iOS)
import CmuxMobileDesign
import SwiftUI

/// Taste prototype (off by default, `CmuxMobilePreferences.Key.tabCardMonograms`): a browser
/// card with no picture yet shows the site's letter on a hue of its own instead of the grey
/// globe, so a grid of unvisited pages still tells them apart (Leo, 2026-11-22: "there should be
/// no reason for there to be so many blank favicons and blank previews and blank pages").
/// The site is the address's registrable part, so every apple.com tab shares one letter and hue.
enum SiteMonogram {
    /// The part of `host` a person would name the site by: `developer.apple.com` → `apple`,
    /// `news.bbc.co.uk` → `bbc`, `localhost` → `localhost`; nil without letters or digits.
    static func site(_ host: String?) -> String? {
        guard let host = host?.lowercased(), !host.isEmpty else { return nil }
        var labels = host.split(separator: ".").map(String.init).filter { !$0.isEmpty }
        if labels.first == "www" { labels.removeFirst() }
        // An IP address names no site: its first number stands in.
        if labels.count == 4, labels.allSatisfy({ Int($0) != nil }) { return labels[0] }
        if labels.count >= 3, labels[labels.count - 2].count <= 3, labels[labels.count - 1].count == 2 {
            labels.removeLast() // a country's second level (co.uk, com.au): the name is before it
        }
        let name = labels.count >= 2 ? labels[labels.count - 2] : labels.first
        return name.flatMap { $0.contains(where: { $0.isLetter || $0.isNumber }) ? $0 : nil }
    }

    /// The card's letter: the site's first letter or digit, uppercased.
    static func letter(_ host: String?) -> String? {
        site(host).flatMap { $0.first(where: { $0.isLetter || $0.isNumber }) }.map { String($0).uppercased() }
    }

    /// The host under the letter, as the toolbar's short label shows it (no `www.`).
    static func label(_ host: String?) -> String {
        guard let host else { return "" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// The site's hue, 0..<1: FNV-1a of its name, so it is the same on every launch and device
    /// (`hashValue` is seeded per process).
    static func hue(_ host: String?) -> Double {
        var hash: UInt32 = 2_166_136_261
        for byte in (site(host) ?? "").utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return Double(hash % 360) / 360
    }
}

/// The monogram card face, laid out at the full page size like every card (the grid scales it
/// down). `style` is the gallery's variant; the card uses `.tile`.
struct SiteMonogramFace: View {
    enum Style: String, CaseIterable {
        case tile, wash, letterOnly

        /// The gallery's row title: A is the one the setting turns on.
        var galleryTitle: String {
            switch self {
            case .tile: "A tile"
            case .wash: "B wash"
            case .letterOnly: "C letter only"
            }
        }
    }

    let host: String?
    var style: Style = .tile
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let hue = SiteMonogram.hue(host)
        let fill = Color(hue: hue, saturation: scheme == .dark ? 0.55 : 0.6, brightness: scheme == .dark ? 0.62 : 0.82)
        let letter = SiteMonogram.letter(host) ?? "?"
        let label = SiteMonogram.site(host) == nil ? "" : SiteMonogram.label(host)
        ZStack {
            switch style {
            case .tile:
                Color(uiColor: .systemBackground)
                VStack(spacing: 22) {
                    Text(letter)
                        .font(.system(size: 76, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(width: 136, height: 136)
                        .background(fill, in: .rect(cornerRadius: 32, style: .continuous))
                    Text(label).font(.system(size: 26, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.horizontal, 24)
            case .wash:
                fill.opacity(scheme == .dark ? 0.45 : 0.28)
                Text(letter)
                    .font(.system(size: 180, weight: .bold, design: .rounded))
                    .foregroundStyle(fill)
            case .letterOnly:
                Color(uiColor: .systemBackground)
                Text(letter)
                    .font(.system(size: 120, weight: .light, design: .rounded))
                    .foregroundStyle(fill)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityHidden(true)
    }
}

#if DEBUG
/// Gallery (`-cmux-mobile-recovery-gallery favicons`): browser cards with no picture, as the grid
/// draws them at card scale. Off: today's globe. A (the one the setting turns on): the letter on
/// the site's hue in a tile, the host under it. B: the whole card washed in the hue. C: the letter
/// alone in the hue.
public struct SiteMonogramGallery: View {
    static let hosts = ["developer.apple.com", "github.com", "news.ycombinator.com", "localhost", "www.bbc.co.uk", "192.168.1.20"]

    /// The page a gallery card is laid out at before it is scaled to 110 pt wide, as TabsKit does.
    static let page = CGSize(width: 400, height: 611)

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                row("Off (today)") { _ in
                    BrowserCard(model: nil, insets: EdgeInsets(), lastKnown: nil, host: nil)
                }
                // visible-only: a fixed gallery of three variants by six hosts (a DEBUG screenshot page).
                ForEach(SiteMonogramFace.Style.allCases, id: \.self) { style in
                    row(style.galleryTitle) { host in SiteMonogramFace(host: host, style: style) }
                }
            }
            .padding(16)
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private func row<Face: View>(_ title: String, @ViewBuilder face: @escaping (String) -> Face) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    // visible-only: the gallery's six fixed hosts, unique by name.
                    ForEach(Self.hosts, id: \.self) { host in
                        VStack(spacing: 4) {
                            // A page-sized face scaled to a grid card, as TabsKit does.
                            face(host)
                                .frame(width: Self.page.width, height: Self.page.height)
                                .scaleEffect(110 / Self.page.width, anchor: .topLeading)
                                .frame(width: 110, height: 168, alignment: .topLeading)
                                .clipShape(.rect(cornerRadius: 12, style: .continuous))
                            Text(host).font(.caption2).foregroundStyle(.secondary).lineLimit(1).frame(width: 110)
                        }
                    }
                }
            }
        }
    }
}
#endif
#endif
