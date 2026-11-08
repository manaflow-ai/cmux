import SwiftUI

/// Keeps a lazily restored browser tab's pane occupied until its host reports a reveal.
struct DeferredBrowserPanelView: View {
    let isVisibleInUI: Bool
    let onRequestMaterialization: () -> Void
    let onRequestPanelFocus: () -> Void

    var body: some View {
        ZStack {
            Color.clear
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onAppear {
            guard isVisibleInUI else { return }
            onRequestMaterialization()
        }
        .onChange(of: isVisibleInUI) { _, visible in
            guard visible else { return }
            onRequestMaterialization()
        }
        .onTapGesture {
            onRequestPanelFocus()
        }
    }
}
