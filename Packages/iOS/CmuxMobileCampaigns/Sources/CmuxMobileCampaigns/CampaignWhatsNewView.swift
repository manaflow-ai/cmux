#if os(iOS)
public import SwiftUI

/// Settings > What's New: targeted campaigns stay findable here after their
/// live surfaces are dismissed, so announcements never occupy primary screen
/// real estate.
public struct CampaignWhatsNewView: View {
    private let center: MobileCampaignCenter

    @State private var selectedCampaign: Campaign?

    public init(center: MobileCampaignCenter) {
        self.center = center
    }

    /// The localized navigation title, shared with the Settings row label.
    public static var title: String {
        String(localized: "campaign.whatsNew.title", defaultValue: "What's New", bundle: .module)
    }

    public var body: some View {
        Group {
            if center.whatsNewCampaigns.isEmpty {
                ContentUnavailableView(
                    Self.title,
                    systemImage: "sparkles",
                    description: Text(String(
                        localized: "campaign.whatsNew.empty",
                        defaultValue: "No announcements yet.",
                        bundle: .module
                    ))
                )
            } else {
                List(center.whatsNewCampaigns) { campaign in
                    Button {
                        selectedCampaign = campaign
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(campaign.title.resolved(
                                languageCode: CampaignCardContent.languageCode
                            ))
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)
                            Text(campaign.body.resolved(
                                languageCode: CampaignCardContent.languageCode
                            ))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        }
                    }
                }
            }
        }
        .navigationTitle(Self.title)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("CampaignWhatsNewList")
        .onAppear {
            center.recordWhatsNewOpened()
        }
        .sheet(item: $selectedCampaign) { campaign in
            CampaignSheetView(campaign: campaign, center: center) {
                selectedCampaign = nil
            }
        }
    }
}
#endif
