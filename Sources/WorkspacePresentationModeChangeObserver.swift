import SwiftUI

struct WorkspacePresentationModeChangeObserver: View {
    let onChange: (WorkspaceTitlebarSettings) -> Void

    @WorkspaceTitlebarConfiguration private var titlebarSettings

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .onAppear {
                onChange(titlebarSettings)
            }
            .onChange(of: titlebarSettings) { _, newValue in
                onChange(newValue)
            }
    }
}
