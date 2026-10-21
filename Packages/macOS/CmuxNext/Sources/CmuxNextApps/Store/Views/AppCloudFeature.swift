import CmuxNextDesign
import CmuxNextIcons
import SwiftUI

/// The featured Cloud banner at the top of Discover: what a cloud machine
/// gives, and one button that opens the Cloud app's page (`app.open`), whose
/// storefront shows the plan's sizes and Get. It states no price or limit;
/// the Cloud page reads those from the plan. Shown only while the App wires
/// ``AppStoreModel/onOpenApp``.
struct AppCloudFeature: View {
    let open: @MainActor (String) -> Void
    @Environment(\.appSceneColors) private var colors

    /// The Cloud app (first-party-apps/cloud): its page holds the storefront.
    static let cloudAppID = "cmux/cloud"

    var body: some View {
        HStack(spacing: Metrics.space4) {
            VStack(alignment: .leading, spacing: 2) {
                Text(AppsStrings.cloudFeatureEyebrow)
                    .font(Font(Typography.caption)).foregroundStyle(colors.tertiary)
                Text(AppsStrings.cloudFeatureTitle)
                    .font(Font(Typography.header)).foregroundStyle(colors.primary)
                Text(AppsStrings.cloudFeatureBody)
                    .font(Font(Typography.caption)).foregroundStyle(colors.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Icon(.cloud, size: 28).foregroundStyle(colors.tertiary)
            Button { open(Self.cloudAppID) } label: {
                Text(AppsStrings.cloudFeatureOpen)
                    .font(Font(Typography.bodyEmphasized))
                    .foregroundStyle(colors.primary)
                    .padding(.horizontal, Metrics.space3)
                    .frame(height: AppStoreColumn.actionHeight)
                    .background(RoundedRectangle(cornerRadius: Metrics.itemCornerRadius, style: .continuous).fill(colors.selection))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("appStore.cloudFeature.open")
        }
        .padding(Metrics.space4)
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(colors.separator, lineWidth: Borders.width(1)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("appStore.cloudFeature")
    }
}
