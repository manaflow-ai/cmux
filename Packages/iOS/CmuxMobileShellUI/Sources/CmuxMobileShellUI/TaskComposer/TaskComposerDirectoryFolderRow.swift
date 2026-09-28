#if os(iOS)
import CmuxMobileRPC
import SwiftUI

/// One subfolder row in the directory browser: folder glyph with Finder-style
/// alias and hidden badges, the folder name, and a trailing lock when the Mac
/// cannot read it.
struct TaskComposerDirectoryFolderRow: View {
    let entry: MobileTaskDirectoryListEntry

    var body: some View {
        HStack(spacing: 12) {
            icon

            Text(entry.name)
                .foregroundStyle(entry.isHidden ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            if !entry.isReadable {
                Image(systemName: "lock.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
    }

    private var icon: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: entry.isPackage ? "shippingbox.fill" : "folder.fill")
                .font(.title3)
                .foregroundStyle(.tint)
                .opacity(entry.isHidden ? 0.5 : 1)
            if entry.isSymbolicLink {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(2)
                    .background(.background, in: Circle())
                    .offset(x: 3, y: 2)
            }
        }
        .accessibilityHidden(true)
    }
}
#endif
