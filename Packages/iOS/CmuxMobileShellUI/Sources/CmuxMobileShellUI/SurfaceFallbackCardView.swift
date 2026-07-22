import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// Placeholder for a surface that remains rendered by the paired Mac.
struct SurfaceFallbackCardView: View {
    let surface: MobileSurfacePreview
    let canOpenOnMac: Bool
    let openOnMac: () async -> Bool

    @State private var focusFailed = false
    @State private var focusTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: surface.kind.systemImage)
                .font(.system(size: 38))
            Text(surface.title).font(.headline)
            Text(surface.kind.displayName).foregroundStyle(.secondary)
            Text(L10n.string("mobile.surface.renderedOnMac", defaultValue: "Rendered on your Mac"))
                .foregroundStyle(.secondary)
            Button {
                focusTask?.cancel()
                focusTask = Task {
                    let succeeded = await openOnMac()
                    guard !Task.isCancelled else { return }
                    focusFailed = !succeeded
                }
            } label: {
                Label(
                    L10n.string("mobile.surface.openOnMac", defaultValue: "Open on Mac"),
                    systemImage: "macwindow"
                )
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canOpenOnMac)
            if focusFailed {
                Text(L10n.string(
                    "mobile.surface.openOnMacFailed",
                    defaultValue: "Couldn't reach your Mac. Try again."
                ))
                .font(.footnote)
                .foregroundStyle(.red)
            }
        }
        .multilineTextAlignment(.center)
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDisappear { focusTask?.cancel() }
    }
}
