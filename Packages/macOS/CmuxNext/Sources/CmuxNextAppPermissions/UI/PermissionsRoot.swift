import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class PermissionsAppearance {
    var colors = AppPermissionsColors()
}

/// Reads the style and colors in a tracked scope so a Debug Settings or
/// theme change updates the surface live.
struct PermissionsRoot: View {
    var surface: AppPermissionsSurface
    var style: any AppPermissionsStyleSource
    var installedStyle: (any AppInstalledStyleSource)?
    var appearance: PermissionsAppearance
    var scrolls: Bool

    var body: some View {
        Group {
            if scrolls {
                ScrollView { content }.scrollIndicators(.automatic)
            } else {
                content
            }
        }
        .background(appearance.colors.background)
        .environment(\.permissionColors, appearance.colors)
    }

    @ViewBuilder private var content: some View {
        switch surface {
        case .consent(let model): ConsentSheetView(model: model, style: style.permissionsStyle)
        case .permissions(let model): PermissionsPaneView(model: model, style: style.permissionsStyle)
        case .firstUse(let prompt): FirstUsePromptView(prompt: prompt)
        case .installed(let model):
            InstalledAppsView(model: model, style: installedStyle?.installedStyle ?? .defaultStyle) { model.presentHidden() }
        case .hiddenApps(let model): HiddenAppsSheetView(model: model) { model.dismissHidden() }
        }
    }

    func measured(width: CGFloat) -> CGFloat {
        let probe = NSHostingController(rootView: content.environment(\.permissionColors, appearance.colors).frame(width: width))
        return ceil(probe.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height)
    }
}
