import CoreGraphics
import SwiftUI

struct WindowSidebarView: View {
    let windows: [HostWindow]
    let selectedWindowID: CGWindowID?
    @Binding var searchText: String
    let onRefresh: () -> Void
    let onSelect: (CGWindowID) -> Void

    var body: some View {
        List {
            ForEach(windows) { window in
                Button {
                    onSelect(window.id)
                } label: {
                    WindowRowView(window: window, isSelected: window.id == selectedWindowID)
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle(String(localized: "sidebar.title", defaultValue: "Windows", bundle: .module))
        .searchable(
            text: $searchText,
            placement: .sidebar,
            prompt: Text(String(localized: "sidebar.search", defaultValue: "Search windows", bundle: .module))
        )
        .toolbar {
            ToolbarItem {
                Button(action: onRefresh) {
                    Label(
                        String(localized: "button.refresh", defaultValue: "Refresh", bundle: .module),
                        systemImage: "arrow.clockwise"
                    )
                }
                .help(String(localized: "button.refresh", defaultValue: "Refresh", bundle: .module))
            }
        }
        .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 380)
    }
}

private struct WindowRowView: View {
    let window: HostWindow
    let isSelected: Bool

    private var title: String {
        window.hasTitle
            ? window.title
            : String(localized: "window.untitled", defaultValue: "Untitled", bundle: .module)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "macwindow")
                .font(.title3)
                .foregroundStyle(isSelected ? .white : .secondary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.callout)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(window.ownerName)
                        .lineLimit(1)
                    if !window.isOnScreen {
                        Label(
                            String(localized: "window.location.otherDesktop", defaultValue: "Other Desktop", bundle: .module),
                            systemImage: "rectangle.on.rectangle"
                        )
                        .labelStyle(.titleAndIcon)
                    }
                }
                .font(.caption)
                .foregroundStyle(isSelected ? .white.opacity(0.82) : .secondary)
                Text(frameSummary(for: window))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(isSelected ? Color.white.opacity(0.68) : Color.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor)
            }
        }
        .contentShape(Rectangle())
    }

    private func frameSummary(for window: HostWindow) -> String {
        let format = String(localized: "window.frame.compact", defaultValue: "%.0f x %.0f", bundle: .module)
        return String(format: format, window.frame.width, window.frame.height)
    }
}
