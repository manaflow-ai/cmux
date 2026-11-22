import AppKit
import CmuxNextDesign
import SwiftUI

/// An app's icon: an SF Symbol on a quiet tile, or the bundle's image.
struct AppIconView: View {
    let icon: AppIcon?
    let bundleDirectory: URL?
    var size: CGFloat = 40
    @Environment(\.appSceneColors) private var colors

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
        ZStack {
            shape.fill(colors.hover)
            switch icon {
            case .file(let path)?:
                if let image = AppBundleImageCache.shared.image(path: path, in: bundleDirectory) {
                    Image(nsImage: image).resizable().scaledToFit().padding(size * 0.14)
                } else {
                    symbol("app")
                }
            case .symbol(let name)?: symbol(name)
            case nil: symbol("app")
            }
        }
        .frame(width: size, height: size)
        .overlay(shape.strokeBorder(colors.separator, lineWidth: Borders.drawsLines ? 0.5 : 0))
        .accessibilityHidden(true)
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: size * 0.46, weight: .regular))
            .foregroundStyle(colors.primary)
    }
}

/// A small label (tier, Installed, Disabled, Local) on a small-radius tile.
struct AppStoreBadge: View {
    let text: String
    var emphasized = false
    @Environment(\.appSceneColors) private var colors

    var body: some View {
        Text(text)
            .font(Font(Typography.caption))
            .foregroundStyle(emphasized ? colors.primary : colors.secondary)
            .padding(.horizontal, Metrics.space2 - 2)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: AppStoreColumn.tagRadius, style: .continuous)
                .fill(emphasized ? colors.selection : colors.hover))
    }
}

/// Install, or Remove for an installed app (user gesture; never
/// automation). Remove is a quiet destructive text button with no
/// confirmation: it is undone from the same place until it commits
/// (`AppStoreModel.requestRemove`). A built-in app has none. Every state
/// keeps the same height, so the header never shifts.
struct AppInstallButton: View {
    let model: AppStoreModel
    let id: String
    var builtIn = false
    @State private var busy = false
    @Environment(\.appSceneColors) private var colors

    var body: some View {
        Group {
            if model.pendingRemoval == id {
                HStack(spacing: Metrics.space2) {
                    Text(AppsStrings.removed).foregroundStyle(colors.secondary)
                    textButton(AppsStrings.undo, color: colors.primary) { await model.undoRemove() }
                        .accessibilityIdentifier("appStore.undoRemove.\(id)")
                }
                .font(Font(Typography.body))
            } else if builtIn {
                Color.clear.frame(width: 0)
            } else if model.state(of: id)?.isInstalled == true {
                textButton(AppsStrings.remove, color: colors.danger) { await model.requestRemove(id) }
                    .font(Font(Typography.body))
                    .accessibilityIdentifier("appStore.install.\(id)")
            } else {
                Button { run { try? await model.install(id) } } label: {
                    Text(AppsStrings.install)
                        .font(Font(Typography.bodyEmphasized))
                        .foregroundStyle(colors.primary)
                        .padding(.horizontal, Metrics.space3)
                        .frame(height: AppStoreColumn.actionHeight)
                        .background(RoundedRectangle(cornerRadius: Metrics.itemCornerRadius, style: .continuous).fill(colors.selection))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(busy)
                .accessibilityIdentifier("appStore.install.\(id)")
            }
        }
        .frame(minHeight: AppStoreColumn.actionHeight)
    }

    private func textButton(_ title: String, color: Color, action: @escaping () async -> Void) -> some View {
        Button { run(action) } label: {
            Text(title).foregroundStyle(color).padding(.horizontal, Metrics.space1).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }

    private func run(_ action: @escaping () async -> Void) {
        busy = true
        // task-owner: one install, remove or undo from a button press
        Task {
            await action()
            busy = false
        }
    }
}
