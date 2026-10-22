import CmuxNextDesign
import SwiftUI

/// The store's cards (apps and features): glass over the page, tinted with the theme's hover
/// fill, a hairline rim, and the selection tint while hovered. Reduce Transparency turns the
/// material solid on its own.
struct AppStoreCardStyle: ViewModifier {
    var hovered = false
    @Environment(\.appSceneColors) private var colors

    static let radius: CGFloat = 12
    /// The grid's narrowest card; columns are added as the window widens.
    static let minimumWidth: CGFloat = 240

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        content
            .background(shape.fill(hovered ? colors.selection : colors.hover))
            .background(.ultraThinMaterial, in: shape)
            .overlay(shape.strokeBorder(colors.separator, lineWidth: Borders.width(1)))
    }
}

extension View {
    func appStoreCard(hovered: Bool = false) -> some View { modifier(AppStoreCardStyle(hovered: hovered)) }
}

/// The store's responsive card grid: as many columns as fit, each at least the card look's
/// minimum width (``AppStoreCardLook/minimumCardWidth``).
struct AppStoreCardGrid<Content: View>: View {
    var look: AppStoreCardLook = .compact
    @ViewBuilder let content: () -> Content

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: look.minimumCardWidth), spacing: look == .row ? Metrics.space3 : Metrics.space4, alignment: .top)],
                  alignment: .leading, spacing: look == .row ? Metrics.space3 : Metrics.space4, content: content)
    }
}

/// What an item card shows for an item: a feature's preview (a small cmux window, a painting,
/// sidebar rows) or an app's icon.
enum AppStoreArtwork {
    case feature(AppFeature.Preview)
    case app(AppIcon?, URL?)
}

extension AppStoreCardLook {
    /// The narrowest card of this look's grid: a row needs room for its actions at the end.
    var minimumCardWidth: CGFloat {
        switch self {
        case .compact: AppStoreCardStyle.minimumWidth
        case .artwork: 280
        case .row: 380
        }
    }
}

/// One state label of an item (On, Installed, Disabled, a tier).
struct AppStoreItemState: Hashable {
    let text: String
    var emphasized = false
}

/// The one card of the App Store, for features and apps alike, in the `apps.store.cardStyle`
/// look: artwork, name, an optional byline (the publisher), the description with its lines
/// reserved (so the cards of a row keep their footers on one line), the item's states, an
/// optional secondary action (Settings…) and the primary action (Get / Remove, Install / Remove).
/// A click on the body, outside the actions, opens the item's page.
struct AppStoreItemCard<Secondary: View, Primary: View>: View {
    let look: AppStoreCardLook
    let artwork: AppStoreArtwork
    let name: String
    let byline: String?
    let summary: String
    let states: [AppStoreItemState]
    let help: String?
    /// Opens the item's page; nil: the body is not a button.
    let open: (() -> Void)?
    let secondary: Secondary
    let primary: Primary
    @State private var hovered = false
    @Environment(\.appSceneColors) private var colors

    init(look: AppStoreCardLook, artwork: AppStoreArtwork, name: String, byline: String? = nil, summary: String,
         states: [AppStoreItemState] = [], help: String? = nil, open: (() -> Void)? = nil,
         @ViewBuilder secondary: () -> Secondary, @ViewBuilder primary: () -> Primary) {
        self.look = look
        self.artwork = artwork
        self.name = name
        self.byline = byline
        self.summary = summary
        self.states = states
        self.help = help
        self.open = open
        self.secondary = secondary()
        self.primary = primary()
    }

    var body: some View {
        Group {
            switch look {
            case .compact, .artwork: stacked
            case .row: row
            }
        }
        .padding(look == .row ? Metrics.space3 : Metrics.space4)
        .appStoreCard(hovered: hovered)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture { open?() }
        .modifier(AppStoreOptionalHelp(text: help))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(name)
        .accessibilityAddTraits(open == nil ? [] : .isButton)
        .accessibilityAction { open?() }
    }

    // MARK: Compact and artwork: the artwork over the text and the action row

    private var stacked: some View {
        VStack(alignment: .leading, spacing: Metrics.space3) {
            AppStoreArtworkView(artwork: artwork, size: look == .artwork ? .tall : .banner)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(Font(Typography.bodyEmphasized)).foregroundStyle(colors.primary).lineLimit(1)
                if let byline { Text(byline).font(Font(Typography.caption)).foregroundStyle(colors.tertiary).lineLimit(1) }
                Text(summary)
                    .font(Font(Typography.caption)).foregroundStyle(colors.secondary)
                    .lineLimit(look == .artwork ? 1 : 2, reservesSpace: true)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            HStack(spacing: Metrics.space2) {
                stateBadges
                secondary
                Spacer(minLength: 0)
                primary
            }
            .frame(height: AppStoreColumn.actionHeight)
        }
    }

    // MARK: Row: small artwork, text, actions at the end

    private var row: some View {
        HStack(spacing: Metrics.space3) {
            AppStoreArtworkView(artwork: artwork, size: .thumbnail)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Metrics.space2) {
                    Text(name).font(Font(Typography.bodyEmphasized)).foregroundStyle(colors.primary).lineLimit(1)
                    stateBadges
                }
                Text(byline.map { "\($0) · \(summary)" } ?? summary)
                    .font(Font(Typography.caption)).foregroundStyle(colors.secondary).lineLimit(1, reservesSpace: true)
            }
            .layoutPriority(1)
            Spacer(minLength: Metrics.space2)
            secondary
            primary
        }
        .frame(minHeight: AppStoreArtworkView.Size.thumbnail.height)
    }

    private var stateBadges: some View {
        ForEach(states, id: \.self) { AppStoreBadge(text: $0.text, emphasized: $0.emphasized) }
    }
}

/// The card's tooltip, when it has one.
private struct AppStoreOptionalHelp: ViewModifier {
    let text: String?

    func body(content: Content) -> some View {
        if let text { content.themedHelp(text) } else { content }
    }
}

/// An item's artwork at one of the store's sizes: a feature's preview fills the width (or a
/// thumbnail of it), an app's icon sits on a tile of the same height.
struct AppStoreArtworkView: View {
    enum Size {
        /// Compact cards: the width, 88 points tall.
        case banner
        /// Artwork cards: the width, 140 points tall.
        case tall
        /// Row cards: a small fixed thumbnail.
        case thumbnail

        var height: CGFloat {
            switch self {
            case .banner: 88
            case .tall: 140
            case .thumbnail: 56
            }
        }
    }

    let artwork: AppStoreArtwork
    let size: Size
    @Environment(\.appSceneColors) private var colors

    var body: some View {
        switch artwork {
        case .feature(let preview):
            switch size {
            case .banner, .tall:
                AppFeaturePreviewView(preview: preview, height: size.height)
            case .thumbnail:
                // The banner drawn at its own size and scaled down, so the window's parts keep their proportions.
                let scale: CGFloat = 0.5
                let width = size.height * 1.6
                AppFeaturePreviewView(preview: preview, height: size.height / scale)
                    .frame(width: width / scale)
                    .scaleEffect(scale)
                    .frame(width: width, height: size.height)
            }
        case .app(let icon, let bundleDirectory):
            switch size {
            case .banner:
                AppIconView(icon: icon, bundleDirectory: bundleDirectory, size: 44).frame(maxWidth: .infinity, alignment: .leading)
            case .tall:
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(colors.selection)
                    AppIconView(icon: icon, bundleDirectory: bundleDirectory, size: 64)
                }
                .frame(maxWidth: .infinity)
                .frame(height: size.height)
                .accessibilityHidden(true)
            case .thumbnail:
                AppIconView(icon: icon, bundleDirectory: bundleDirectory, size: 40)
            }
        }
    }
}

/// The store's row of category chips (Discover and Features): one selected chip, tinted.
struct AppStoreCategoryBar: View {
    struct Chip: Identifiable {
        let id: String
        let title: String
        let selected: Bool
        let select: () -> Void
    }

    let chips: [Chip]
    @Environment(\.appSceneColors) private var colors

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Metrics.space2) {
                ForEach(chips) { chip in
                    Button(action: chip.select) {
                        Text(chip.title)
                            .font(Font(Typography.caption))
                            .foregroundStyle(chip.selected ? colors.primary : colors.secondary)
                            .padding(.horizontal, Metrics.space3)
                            .padding(.vertical, Metrics.space1)
                            .background(RoundedRectangle(cornerRadius: Metrics.itemCornerRadius, style: .continuous)
                                .fill(chip.selected ? colors.selection : colors.hover))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(chip.selected ? .isSelected : [])
                    .accessibilityIdentifier("appStore.category.\(chip.id)")
                }
            }
            .padding(.vertical, Metrics.space3)
            .thinScrollers()
        }
    }
}
