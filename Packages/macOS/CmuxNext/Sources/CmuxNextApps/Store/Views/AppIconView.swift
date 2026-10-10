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

/// A small capsule label (tier, Installed, Disabled, Local).
struct AppStoreBadge: View {
    let text: String
    var emphasized = false
    @Environment(\.appSceneColors) private var colors

    var body: some View {
        Text(text)
            .font(Font(Typography.caption))
            .foregroundStyle(emphasized ? colors.primary : colors.secondary)
            .padding(.horizontal, Metrics.space2)
            .padding(.vertical, 1)
            .background(Capsule().fill(emphasized ? colors.selection : colors.hover))
    }
}

/// Install or Remove for a listing (user gesture; never automation).
struct AppInstallButton: View {
    let model: AppStoreModel
    let id: String
    @State private var busy = false
    @Environment(\.appSceneColors) private var colors

    var body: some View {
        let installed = model.state(of: id)?.isInstalled == true
        Button {
            busy = true
            // task-owner: one install/remove from a button press
            Task {
                if installed { try? await model.remove(id) } else { try? await model.install(id) }
                busy = false
            }
        } label: {
            Text(installed ? AppsStrings.remove : AppsStrings.install)
                .font(Font(Typography.bodyEmphasized))
                .foregroundStyle(installed ? colors.danger : colors.primary)
                .padding(.horizontal, Metrics.space4)
                .padding(.vertical, Metrics.space1 + 1)
                .background(Capsule().fill(installed ? colors.hover : colors.selection))
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .accessibilityIdentifier("appStore.install.\(id)")
    }
}
