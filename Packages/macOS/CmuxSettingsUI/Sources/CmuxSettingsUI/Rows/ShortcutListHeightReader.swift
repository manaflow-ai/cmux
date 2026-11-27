import SwiftUI

struct ShortcutListHeightReader: View {
    let onHeightChange: (CGFloat) -> Void

    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { onHeightChange(proxy.size.height) }
                .onChange(of: proxy.size.height) { _, height in
                    onHeightChange(height)
                }
        }
    }
}
