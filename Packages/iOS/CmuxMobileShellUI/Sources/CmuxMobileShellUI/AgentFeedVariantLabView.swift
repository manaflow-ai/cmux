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
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(L10n.string("mobile.feed.lab.title", defaultValue: "Feed compositions"))
                    .font(.title2.weight(.bold))
                Text(L10n.string(
                    "mobile.feed.lab.description",
                    defaultValue: "Switch the live Feed between five visual languages. Every card uses the same actions and data."
                ))
                .font(.subheadline)
                .foregroundStyle(.secondary)

                Picker(
                    L10n.string("mobile.feed.lab.picker", defaultValue: "Composition"),
                    selection: $displaySettings.agentFeedVariant
                ) {
                    ForEach(AgentFeedVariant.allCases) { variant in
                        Label(variant.title, systemImage: variant.symbolName)
                            .tag(variant)
                    }
                }
                .pickerStyle(.inline)
                .accessibilityIdentifier("MobileSettingsAgentFeedVariantPicker")

                VStack(alignment: .leading, spacing: 8) {
                    Label(displaySettings.agentFeedVariant.title, systemImage: displaySettings.agentFeedVariant.symbolName)
                        .font(.headline)
                    Text(displaySettings.agentFeedVariant.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                AgentFeedView(
                    store: fixtureStore,
                    variant: displaySettings.agentFeedVariant
                )
                .frame(minHeight: 620)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                }
            }
            .padding(18)
        }
        .navigationTitle(L10n.string("mobile.feed.lab.navigationTitle", defaultValue: "Feed Lab"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
