#if DEBUG && os(iOS)
import CmuxMobileSupport
import SwiftUI

/// CMUX Labs picker for comparing all five Feed compositions against the same
/// complete, deterministic coding transcript.
struct AgentFeedVariantLabView: View {
    @Environment(MobileDisplaySettings.self) private var displaySettings
    @State private var fixtureStore = AgentFeedStore.fixture()

    var body: some View {
        @Bindable var displaySettings = displaySettings
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.string("mobile.feed.lab.title", defaultValue: "Feed compositions"))
                    .font(.title2.weight(.bold))
                Text(L10n.string(
                    "mobile.feed.lab.description",
                    defaultValue: "Switch the live Feed between five visual languages. Every card uses the same actions and data."
                ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(AgentFeedVariant.allCases) { variant in
                        let isSelected = displaySettings.agentFeedVariant == variant
                        Button {
                            displaySettings.agentFeedVariant = variant
                        } label: {
                            Label(variant.title, systemImage: variant.symbolName)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(isSelected ? Color.white : .primary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 9)
                                .background(
                                    isSelected ? Color.accentColor : Color.primary.opacity(0.07),
                                    in: Capsule()
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("AgentFeedVariantOption-\(variant.rawValue)")
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 18)
            }
            .accessibilityLabel(
                L10n.string("mobile.feed.lab.picker", defaultValue: "Composition")
            )
            .accessibilityIdentifier("MobileSettingsAgentFeedVariantPicker")

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: displaySettings.agentFeedVariant.symbolName)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(displaySettings.agentFeedVariant.title)
                        .font(.headline)
                    Text(displaySettings.agentFeedVariant.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 18)

            AgentFeedView(
                store: fixtureStore,
                variant: displaySettings.agentFeedVariant
            )
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
            }
        }
        .padding(.top, 12)
        .navigationTitle(L10n.string("mobile.feed.lab.navigationTitle", defaultValue: "Feed Lab"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
