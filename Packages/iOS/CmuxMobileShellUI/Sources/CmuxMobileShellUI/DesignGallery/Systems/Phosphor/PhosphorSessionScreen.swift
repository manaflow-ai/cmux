#if DEBUG
import SwiftUI

/// Renders the complete fixture transcript as Phosphor's primary content surface.
struct PhosphorSessionScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var command = ""
    private var typography = PhosphorTypography()

    private let workspace = DesignGalleryFixtures.workspaces[1]

    var body: some View {
        let theme = PhosphorTheme(scheme: colorScheme)

        VStack(spacing: 0) {
            PhosphorSessionHeader(workspace: workspace)

            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(DesignGalleryFixtures.terminalLines) { line in
                        Text(line.text)
                            .font(typography.terminal)
                            .foregroundStyle(theme.terminalColor(line.tone))
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(height: 15.6, alignment: .leading)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            }
            .scrollIndicators(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(theme.bg0)
        }
        .background(theme.bg0.ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PhosphorTerminalAccessory(command: $command)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
    }
}
#endif
