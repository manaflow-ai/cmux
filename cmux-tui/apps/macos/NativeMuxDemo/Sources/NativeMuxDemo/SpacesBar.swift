import SwiftUI

struct SpacesBar: View {
    @Environment(\.localization) private var localization
    let model: FrontendModel
    let snapshot: ResourceSnapshot

    private var screens: [ScreenSnapshot] {
        guard let workspace = model.selectedWorkspace else { return [] }
        return snapshot.screens(in: workspace.id)
    }

    var body: some View {
        let selectedScreenID = model.selectedScreen?.id
        HStack(spacing: 8) {
            Text(localization.text("spaces.title", "Spaces"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal) {
                HStack(spacing: 5) {
                    ForEach(screens) { screen in
                        let selected = screen.id == selectedScreenID
                        Button {
                            model.selectScreen(screen)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: selected ? "circle.inset.filled" : "circle")
                                    .font(.system(size: 8))
                                Text(screen.displayName(localization: localization))
                            }
                            .font(.caption)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(
                                selected ? Color.accentColor.opacity(0.18) : Color.clear,
                                in: .capsule
                            )
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(localization.text("space.close", "Close space"), role: .destructive) {
                                model.closeScreen(screen)
                            }
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
            Button(action: model.createScreen) {
                Image(systemName: "plus")
            }
            .buttonStyle(.plain)
            .help(localization.text("spaces.new", "New space"))
            Divider().frame(height: 17)
            Button(action: model.createAutoPane) {
                Label(
                    localization.text("pane.auto", "Auto pane"),
                    systemImage: "rectangle.stack.badge.plus"
                )
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.plain)
            .help(localization.text("pane.new_auto", "New auto-layout pane"))
            Spacer()
            if let screen = model.selectedScreen,
                case .viewport(_, _) = screen.layout.root,
                let columnCountLabel = screen.columnCountLabel(localization: localization)
            {
                Label(
                    columnCountLabel,
                    systemImage: "rectangle.3.group"
                )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
        .background(.bar)
    }
}
