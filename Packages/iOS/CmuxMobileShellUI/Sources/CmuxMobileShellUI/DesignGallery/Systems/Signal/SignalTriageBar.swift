#if DEBUG
import SwiftUI

/// Keeps the highest-priority fixture decision one thumb tap away.
struct SignalTriageBar: View {
    let theme: SignalTheme

    private var priorityWorkspace: GalleryWorkspaceFixture {
        DesignGalleryFixtures.workspaces[0]
    }

    var body: some View {
        HStack(spacing: 10) {
            SignalStatusSquare(color: theme.needsYou)

            Text("NEEDS YOU · \(priorityWorkspace.name)/\(priorityWorkspace.branch) · \(priorityWorkspace.absoluteTimeText)")
                .font(.system(.footnote, design: .monospaced, weight: .semibold))
                .foregroundStyle(theme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.68)

            Spacer(minLength: 0)

            Button(action: {}) {
                Text("Go")
            }
            .buttonStyle(SignalPressButtonStyle(role: .primary, theme: theme))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(theme.surface)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(theme.hairline)
                .frame(height: 1)
        }
    }
}
#endif
