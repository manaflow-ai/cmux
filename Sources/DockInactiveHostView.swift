import SwiftUI

struct DockInactiveHostView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "dock.rectangle")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(String(
                localized: "dock.inactiveHost.title",
                defaultValue: "Global Dock is active in another window"
            ))
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
