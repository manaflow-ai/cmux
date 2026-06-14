import SwiftUI

/// Mounts the standard-mode workspace titlebar band. Owns the
/// presentation-mode subscription so the band mount/unmount on a minimal-mode
/// toggle does not require re-evaluating the window-root `ContentView` body
/// (https://github.com/manaflow-ai/cmux/issues/5732). The band content is the
/// stored view value from the last `ContentView` render (the band's own
/// inputs — appearance, titles, sidebar width — all re-render `ContentView`
/// when they change, so the stored value is always current).
struct MinimalModeTitlebarBandHost<Band: View>: View {
    let band: Band
    /// Runs the AppKit side effects of a mode flip (window decorations,
    /// chrome metrics, traffic-light inset, portal geometry). Replaces the
    /// `onChange(of: isMinimalMode)` that previously lived on `ContentView`.
    let onModeChange: () -> Void

    @AppStorage(WorkspacePresentationModeSettings.modeKey)
    private var workspacePresentationMode = WorkspacePresentationModeSettings.defaultMode.rawValue

    init(onModeChange: @escaping () -> Void, @ViewBuilder band: () -> Band) {
        self.onModeChange = onModeChange
        self.band = band()
    }

    private var isMinimalMode: Bool {
        WorkspacePresentationModeSettings.mode(for: workspacePresentationMode) == .minimal
    }

    var body: some View {
        Group {
            if !isMinimalMode {
                band
            }
        }
        .onChange(of: isMinimalMode) { _, _ in
            onModeChange()
        }
    }
}
