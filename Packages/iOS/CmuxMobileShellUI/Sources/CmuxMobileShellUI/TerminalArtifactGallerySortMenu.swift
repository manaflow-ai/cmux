#if os(iOS)
import CmuxAgentChat
import SwiftUI

struct TerminalArtifactGallerySortMenu: View, Equatable {
    let value: TerminalArtifactGallerySortMenuValue
    let actions: TerminalArtifactGallerySortMenuActions

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.value == rhs.value
    }

    var body: some View {
        Menu {
            Picker(
                String(
                    localized: "terminal.artifact.gallery.sort",
                    defaultValue: "Sort",
                    bundle: .module
                ),
                selection: Binding(
                    get: { value.sort },
                    set: { actions.setSort($0) }
                )
            ) {
                ForEach(ChatArtifactGallerySort.allCases, id: \.self) { sort in
                    Text(sortTitle(sort)).tag(sort)
                }
            }
        } label: {
            Label(sortTitle(value.sort), systemImage: "arrow.up.arrow.down")
                .font(.subheadline.weight(.medium))
        }
    }

    private func sortTitle(_ sort: ChatArtifactGallerySort) -> String {
        switch sort {
        case .recent:
            String(localized: "terminal.artifact.gallery.sort.recent", defaultValue: "Recent", bundle: .module)
        case .name:
            String(localized: "terminal.artifact.gallery.sort.name", defaultValue: "Name", bundle: .module)
        case .size:
            String(localized: "terminal.artifact.gallery.sort.size", defaultValue: "Size", bundle: .module)
        }
    }
}
#endif
