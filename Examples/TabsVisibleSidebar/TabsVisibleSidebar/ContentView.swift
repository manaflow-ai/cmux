import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "sidebar.leading")
                .imageScale(.large)
                .foregroundStyle(.tint)
            Text(String(localized: "tabsVisible.app.title", defaultValue: "Tabs Visible Sidebar"))
                .font(.title2.weight(.semibold))
            Text(String(
                localized: "tabsVisible.app.detail",
                defaultValue: "Keep this app installed. Enable Tabs Visible Sidebar from cmux Sidebar Extensions, then choose the extension sidebar provider from the sidebar footer puzzle button."
            ))
            .foregroundStyle(.secondary)
            Text(String(
                localized: "tabsVisible.app.scopes",
                defaultValue: "The extension shows workspaces as disclosure groups and lists each workspace surface underneath."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 420, alignment: .leading)
    }
}

#Preview {
    ContentView()
}
