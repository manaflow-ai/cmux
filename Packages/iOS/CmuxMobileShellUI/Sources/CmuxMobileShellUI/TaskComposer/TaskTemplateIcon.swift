#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI
import UIKit

/// Renders a task template's icon: a bundled agent brand image (`agent:`
/// values), an SF Symbol name, or a single emoji.
struct TaskTemplateIcon: View {
    let value: String

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let baseName = MobileTaskTemplate.agentIconAssetName(for: value),
           let image = Self.brandImage(baseName: baseName, darkMode: colorScheme == .dark) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
        } else {
            switch MacAvatarIcon.resolve(custom: value, defaultSymbol: "terminal") {
            case .symbol(let name):
                Image(systemName: name)
                    .accessibilityHidden(true)
            case .emoji(let emoji):
                Text(emoji)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// Brand PNGs are shipped as loose package resources and loaded by explicit
/// file path. This deliberately avoids asset-catalog and `UIImage(named:in:)`
/// lookups: dev reloads apply PRODUCT_BUNDLE_IDENTIFIER to every target, so
/// the SwiftPM resource bundle shares the app's identifier and CoreUI's
/// per-identifier catalog registration resolves against the wrong catalog.
extension TaskTemplateIcon {
    @MainActor private static var brandImageCache: [String: UIImage] = [:]

    /// Returns the brand image for `baseName` (e.g. "Codex"), preferring a
    /// `-dark` variant file in dark mode when one is bundled.
    @MainActor static func brandImage(baseName: String, darkMode: Bool) -> UIImage? {
        if darkMode, let dark = loadBrandImage(fileName: "\(baseName)-dark") {
            return dark
        }
        return loadBrandImage(fileName: baseName)
    }

    @MainActor private static func loadBrandImage(fileName: String) -> UIImage? {
        if let cached = brandImageCache[fileName] {
            return cached
        }
        guard let url = Bundle.module.url(
            forResource: "\(fileName)@3x",
            withExtension: "png",
            subdirectory: "AgentIcons"
        ), let data = try? Data(contentsOf: url),
              let image = UIImage(data: data, scale: 3) else {
            return nil
        }
        brandImageCache[fileName] = image
        return image
    }
}
#endif
