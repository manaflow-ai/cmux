import SwiftUI

struct MobileToolbarPriorityHost<Content: View>: View {
    let role: MobileToolbarItemLayoutRole
    let content: Content

    init(role: MobileToolbarItemLayoutRole, @ViewBuilder content: () -> Content) {
        self.role = role
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
        content
            .layoutPriority(role.swiftUILayoutPriority)
    }
}
