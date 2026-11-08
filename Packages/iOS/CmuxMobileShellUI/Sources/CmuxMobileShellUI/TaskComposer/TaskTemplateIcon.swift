#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI
import UIKit

/// Renders a task template's icon: a bundled agent brand image (`agent:`
/// values), an SF Symbol name, or a single emoji.
struct TaskTemplateIcon: View {
    let value: String
    var size: CGFloat = 18
    var shellVariant: TaskComposerShellIconVariant = .current

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let baseName = MobileTaskTemplate.agentIconAssetName(for: value),
           let image = Self.brandImage(baseName: baseName, darkMode: colorScheme == .dark) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            switch MacAvatarIcon.resolve(custom: value, defaultSymbol: "terminal") {
            case .symbol(let name):
                let usesShellTreatment = name == "terminal"
                Image(systemName: name)
                    .font(.system(
                        size: size * (usesShellTreatment ? shellVariant.glyphScale : 1),
                        weight: usesShellTreatment ? shellVariant.glyphWeight : .semibold
                    ))
                    .opacity(usesShellTreatment ? shellVariant.glyphOpacity : 1)
                    .accessibilityHidden(true)
            case .emoji(let emoji):
                Text(emoji)
                    .font(.system(size: size))
                    .accessibilityHidden(true)
            }
        }
    }
}

/// Brand PNGs are shipped as loose package resources and loaded by explicit
/// file path. SwiftPM flattens processed resource directories into the bundle
/// root. This deliberately avoids asset-catalog and `UIImage(named:in:)`
/// lookups: dev reloads apply PRODUCT_BUNDLE_IDENTIFIER to every target, so
/// the SwiftPM resource bundle shares the app's identifier and CoreUI's
/// per-identifier catalog registration resolves against the wrong catalog.
extension TaskTemplateIcon {
    @MainActor private static let bundledBrandImages: [String: UIImage] = Dictionary(
        uniqueKeysWithValues: ["Claude", "Codex", "Codex-dark", "OpenCode"].compactMap { fileName in
            loadBundledBrandImage(fileName: fileName).map { (fileName, $0) }
        }
    )

    /// Returns the brand image for `baseName` (e.g. "Codex"), preferring a
    /// `-dark` variant file in dark mode when one is bundled.
    @MainActor static func brandImage(baseName: String, darkMode: Bool) -> UIImage? {
        if darkMode, let dark = bundledBrandImages["\(baseName)-dark"] {
            return dark
        }
        return bundledBrandImages[baseName]
    }

    @MainActor private static func loadBundledBrandImage(fileName: String) -> UIImage? {
        guard let url = Bundle.module.url(
            forResource: "\(fileName)@3x",
            withExtension: "png"
        ), let data = try? Data(contentsOf: url),
              let image = UIImage(data: data, scale: 3) else {
            return nil
        }
        return image
    }
}
#endif
