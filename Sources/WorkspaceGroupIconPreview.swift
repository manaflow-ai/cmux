import SwiftUI

struct WorkspaceGroupIconPreview: View, Equatable {
    let icon: RenderableWorkspaceGroupIcon

    var body: some View {
        switch icon {
        case .systemSymbol(let symbol):
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
        case .emoji(let emoji):
            Text(emoji)
                .font(.system(size: 14))
        }
    }
}
