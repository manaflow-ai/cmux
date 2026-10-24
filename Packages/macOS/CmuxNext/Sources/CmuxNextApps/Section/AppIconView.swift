import AppKit
import CmuxNextDesign
import CmuxNextIcons
import SwiftUI

/// An app's icon in its sidebar section header (`apps.section.look` card): an SF Symbol on a quiet
/// tile, or the bundle's image.
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
        Icon(symbol: name, size: size * 0.46)
            .foregroundStyle(colors.primary)
    }
}
