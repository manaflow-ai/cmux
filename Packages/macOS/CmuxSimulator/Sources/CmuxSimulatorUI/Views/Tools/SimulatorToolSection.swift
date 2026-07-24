import SwiftUI

struct SimulatorToolSection<Content: View>: View {
    let title: LocalizedStringResource
    @ViewBuilder let content: Content

    init(
        _ title: LocalizedStringResource,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .controlSize(.small)
        } label: {
            Text(title).font(.headline)
        }
    }
}
