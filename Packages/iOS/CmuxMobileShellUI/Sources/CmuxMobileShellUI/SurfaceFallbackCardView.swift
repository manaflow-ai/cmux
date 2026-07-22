import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// Placeholder for a surface that remains rendered by the paired Mac.
struct SurfaceFallbackCardView: View {
    let surface: MobileSurfacePreview
    let canOpenOnMac: Bool
    let openOnMac: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: surface.kind.systemImage)
                .font(.system(size: 38))
            Text(surface.title).font(.headline)
            Text(surface.kind.displayName).foregroundStyle(.secondary)
            Text(L10n.string("mobile.surface.renderedOnMac", defaultValue: "Rendered on your Mac"))
                .foregroundStyle(.secondary)
            Button(action: openOnMac) {
                Label(
                    L10n.string("mobile.surface.openOnMac", defaultValue: "Open on Mac"),
                    systemImage: "macwindow"
                )
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canOpenOnMac)
        }
        .multilineTextAlignment(.center)
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
