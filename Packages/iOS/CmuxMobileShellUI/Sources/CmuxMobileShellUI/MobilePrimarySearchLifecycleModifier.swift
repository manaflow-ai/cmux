#if os(iOS)
import SwiftUI

struct MobilePrimarySearchLifecycleModifier: ViewModifier {
    @Environment(\.isSearching) private var isSearching

    let scope: MobilePrimarySearchScope
    let update: (MobilePrimarySearchScope, Bool) -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: isSearching, initial: true) { _, isSearching in
                update(scope, isSearching)
            }
            .onDisappear {
                update(scope, false)
            }
    }
}
#endif
