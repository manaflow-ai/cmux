#if os(iOS)
public import SwiftUI
internal import SafariServices

/// Shared slot layout for the sheet and full-screen templates: image, title,
/// body, then buttons. Links open in-app through `SFSafariViewController`.
struct CampaignCardContent: View {
    let campaign: Campaign
    let center: MobileCampaignCenter
    let close: () -> Void

    @State private var inAppURL: IdentifiedURL?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let image = campaign.image {
                    campaignImage(image)
                }
                Text(campaign.title.resolved(languageCode: Self.languageCode))
                    .font(.title2.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(campaign.body.resolved(languageCode: Self.languageCode))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .safeAreaInset(edge: .bottom) {
            if !campaign.buttons.isEmpty {
                VStack(spacing: 10) {
                    ForEach(Array(campaign.buttons.enumerated()), id: \.offset) { _, button in
                        campaignButton(button)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.bar)
            }
        }
        .sheet(item: $inAppURL) { identified in
            CampaignSafariView(url: identified.url)
                .ignoresSafeArea()
        }
    }

    static var languageCode: String {
        Locale.current.language.languageCode?.identifier ?? "en"
    }

    @ViewBuilder
    private func campaignImage(_ image: CampaignImage) -> some View {
        let reference = (colorScheme == .dark ? image.dark : nil) ?? image.light
        if let url = center.imageURL(for: reference) {
            AsyncImage(url: url) { phase in
                switch phase {
                case let .success(loaded):
                    loaded
                        .resizable()
                        .scaledToFit()
                case .failure, .empty:
                    placeholder(aspectRatio: image.aspectRatio)
                @unknown default:
                    placeholder(aspectRatio: image.aspectRatio)
                }
            }
            // Capped so a tall image cannot push the title and body below
            // the sheet's medium detent.
            .frame(maxWidth: .infinity, maxHeight: 220)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityLabel(
                image.alt?.resolved(languageCode: Self.languageCode) ?? ""
            )
        }
    }

    @ViewBuilder
    private func placeholder(aspectRatio: Double?) -> some View {
        Rectangle()
            .fill(.quaternary)
            .aspectRatio(aspectRatio ?? 2, contentMode: .fit)
    }

    @ViewBuilder
    private func campaignButton(_ button: CampaignButton) -> some View {
        let label = Text(button.label.resolved(languageCode: Self.languageCode))
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity)
        Button {
            center.recordButtonTapped(button, in: campaign)
            switch button.action {
            case let .openURL(url):
                // Engaging counts as done: never re-present this campaign.
                center.recordDismissed(campaign, source: "button")
                inAppURL = IdentifiedURL(url: url)
            case .dismiss:
                center.recordDismissed(campaign, source: "button")
                close()
            }
        } label: {
            label
        }
        .buttonStyle(CampaignButtonStyle(role: button.role, accent: campaign.accent))
    }
}

/// The sheet template host.
public struct CampaignSheetView: View {
    private let campaign: Campaign
    private let center: MobileCampaignCenter
    private let close: () -> Void

    public init(campaign: Campaign, center: MobileCampaignCenter, close: @escaping () -> Void) {
        self.campaign = campaign
        self.center = center
        self.close = close
    }

    public var body: some View {
        CampaignCardContent(campaign: campaign, center: center, close: close)
            .overlay(alignment: .topTrailing) {
                CampaignCloseButton(action: close)
                    .padding(12)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .accessibilityIdentifier("CampaignSheet")
    }
}

/// The full-screen takeover template host.
public struct CampaignFullScreenView: View {
    private let campaign: Campaign
    private let center: MobileCampaignCenter
    private let close: () -> Void

    public init(campaign: Campaign, center: MobileCampaignCenter, close: @escaping () -> Void) {
        self.campaign = campaign
        self.center = center
        self.close = close
    }

    public var body: some View {
        NavigationStack {
            CampaignCardContent(campaign: campaign, center: center, close: close)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        CampaignCloseButton(action: close)
                    }
                }
        }
        .accessibilityIdentifier("CampaignFullScreen")
    }
}

/// The inline banner template: a floating card with title, optional first
/// button as the tap action, and an explicit close control.
public struct CampaignBannerView: View {
    private let campaign: Campaign
    private let center: MobileCampaignCenter

    @State private var inAppURL: IdentifiedURL?

    public init(campaign: Campaign, center: MobileCampaignCenter) {
        self.campaign = campaign
        self.center = center
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(campaign.title.resolved(languageCode: CampaignCardContent.languageCode))
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(campaign.body.resolved(languageCode: CampaignCardContent.languageCode))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            CampaignCloseButton {
                center.recordDismissed(campaign, source: "close")
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.quaternary)
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture {
            guard let button = campaign.buttons.first else { return }
            center.recordButtonTapped(button, in: campaign)
            center.recordDismissed(campaign, source: "banner-tap")
            if case let .openURL(url) = button.action {
                inAppURL = IdentifiedURL(url: url)
            }
        }
        .sheet(item: $inAppURL) { identified in
            CampaignSafariView(url: identified.url)
                .ignoresSafeArea()
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: 480)
        .accessibilityIdentifier("CampaignBanner")
    }
}

struct CampaignCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .font(.title3)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
        }
        .accessibilityLabel(String(
            localized: "campaign.close",
            defaultValue: "Close",
            bundle: .module
        ))
        .accessibilityIdentifier("CampaignClose")
    }
}

struct CampaignButtonStyle: ButtonStyle {
    let role: CampaignButton.Role
    let accent: Color?

    func makeBody(configuration: Configuration) -> some View {
        let base = configuration.label
            .padding(.vertical, 12)
            .opacity(configuration.isPressed ? 0.7 : 1)
        switch role {
        case .primary:
            base
                .foregroundStyle(.white)
                .background(
                    accent ?? Color.accentColor,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
        case .secondary:
            base
                .foregroundStyle(accent ?? Color.accentColor)
        }
    }
}

extension Campaign {
    /// The optional "#RRGGBB" accent parsed into a color.
    var accent: Color? {
        guard let accentColor else { return nil }
        var hex = accentColor
        guard hex.hasPrefix("#"), hex.count == 7 else { return nil }
        hex.removeFirst()
        guard let value = UInt32(hex, radix: 16) else { return nil }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

struct IdentifiedURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// In-app browser for campaign links.
struct CampaignSafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
#endif
