#if DEBUG
import SwiftUI

/// Renders Meridian's promoted needs-you section and complete workspace hub.
struct MeridianHubScreen: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("cmux")
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(theme.label)
                .padding(.horizontal, theme.horizontalInset)
                .padding(.top, 14)
                .padding(.bottom, 4)

            List {
                Section("For you") {
                    ForEach(DesignGalleryFixtures.workspaces.prefix(1)) { workspace in
                        MeridianWorkspaceRow(workspace: workspace)
                            .listRowBackground(theme.needsYou.opacity(0.09))
                    }
                }

                Section("Workspaces") {
                    ForEach(DesignGalleryFixtures.workspaces.dropFirst()) { workspace in
                        MeridianWorkspaceRow(workspace: workspace)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background.ignoresSafeArea())
        .tint(theme.accent)
    }

    private var theme: MeridianTheme {
        MeridianTheme(scheme: colorScheme)
    }
}
#endif
