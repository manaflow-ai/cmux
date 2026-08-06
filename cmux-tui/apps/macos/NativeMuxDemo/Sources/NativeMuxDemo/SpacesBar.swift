import SwiftUI

struct SpacesBar: View {
    let model: FrontendModel
    let snapshot: ResourceSnapshot

    private var screens: [ScreenSnapshot] {
        guard let workspace = model.selectedWorkspace else { return [] }
        return snapshot.screens(in: workspace.id)
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(L10n.text("spaces.title", "Spaces"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal) {
                HStack(spacing: 5) {
                    ForEach(screens) { screen in
                        let selected = screen.id == model.selectedScreen?.id
                        Button {
                            model.selectScreen(screen)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: selected ? "circle.inset.filled" : "circle")
                                    .font(.system(size: 8))
                                Text(screen.name?.isEmpty == false
                                    ? screen.name!
                                    : L10n.format("space.number", "%d", screen.index + 1))
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
                            Button(L10n.text("space.close", "Close space"), role: .destructive) {
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
            .help(L10n.text("spaces.new", "New space"))
            Divider().frame(height: 17)
            Button(action: model.createAutoPane) {
                Label(
                    L10n.text("pane.auto", "Auto pane"),
                    systemImage: "rectangle.stack.badge.plus"
                )
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.plain)
            .help(L10n.text("pane.new_auto", "New auto-layout pane"))
            Spacer()
            if let screen = model.selectedScreen,
                case .viewport(_, let columns) = screen.layout.root
            {
                Label(
                    L10n.format("columns.count", "%d columns", columns.count),
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
