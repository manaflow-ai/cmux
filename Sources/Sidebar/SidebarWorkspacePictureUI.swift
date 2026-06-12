import AppKit
import SwiftUI

/// Sidebar UI for per-workspace pictures (iMessage-style avatars): the context
/// menu entrypoints on a workspace row and the small leading avatar. All
/// mutations route through the one shared `TabManager.setWorkspacePicture` /
/// `removeWorkspacePicture` path.
extension TabItemView {
    /// "Workspace Picture" submenu for the workspace context menu.
    @ViewBuilder
    var workspacePictureMenu: some View {
        Menu(String(localized: "contextMenu.workspacePicture", defaultValue: "Workspace Picture")) {
            Button {
                chooseWorkspacePictureFromFile()
            } label: {
                Label(
                    tab.pictureHash == nil
                        ? String(localized: "contextMenu.setWorkspacePicture", defaultValue: "Choose Picture…")
                        : String(localized: "contextMenu.changeWorkspacePicture", defaultValue: "Change Picture…"),
                    systemImage: "photo"
                )
            }

            if WorkspacePicturePasteboardSupport.hasImage {
                Button {
                    pasteWorkspacePicture()
                } label: {
                    Label(
                        String(localized: "contextMenu.pasteWorkspacePicture", defaultValue: "Paste Picture"),
                        systemImage: "doc.on.clipboard"
                    )
                }
            }

            if tab.pictureHash != nil {
                Button {
                    tabManager.removeWorkspacePicture(tabId: tab.id)
                } label: {
                    Label(
                        String(localized: "contextMenu.removeWorkspacePicture", defaultValue: "Remove Picture"),
                        systemImage: "xmark.circle"
                    )
                }
            }
        }
    }

    /// Shared set/change path: pick an image file via NSOpenPanel, then route it
    /// through the single `TabManager.setWorkspacePicture` mutation. The store
    /// downscales and persists; the published hash change updates the sidebar
    /// avatar and pushes to any paired phone.
    private func chooseWorkspacePictureFromFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = String(localized: "panel.workspacePicture.choose", defaultValue: "Choose")
        panel.message = String(
            localized: "panel.workspacePicture.message",
            defaultValue: "Choose an image to use as this workspace's picture."
        )
        guard panel.runModal() == .OK,
              let url = panel.url,
              let image = NSImage(contentsOf: url) else {
            return
        }
        applyWorkspacePicture(image)
    }

    /// Shared paste path: read an image off the general pasteboard and apply it
    /// through the same mutation as the file pick.
    private func pasteWorkspacePicture() {
        guard let image = WorkspacePicturePasteboardSupport.imageFromPasteboard() else {
            NSSound.beep()
            return
        }
        applyWorkspacePicture(image)
    }

    private func applyWorkspacePicture(_ image: NSImage) {
        if !tabManager.setWorkspacePicture(tabId: tab.id, image: image) {
            NSSound.beep()
        }
    }
}

/// Small leading avatar for a workspace that has a picture set. Loads the image
/// from `WorkspacePictureStore` keyed by the immutable `(workspaceId,
/// pictureHash)` value passed in, so the row holds no store reference (snapshot-
/// boundary rule) and the cached `NSImage` only reloads when the hash changes.
struct SidebarWorkspaceAvatarView: View {
    let workspaceId: UUID
    let pictureHash: String
    let size: CGFloat

    @State private var image: NSImage?
    @State private var loadedHash: String?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else {
                Circle()
                    .fill(Color.secondary.opacity(0.2))
                    .frame(width: size, height: size)
            }
        }
        .accessibilityHidden(true)
        .task(id: pictureHash) {
            guard loadedHash != pictureHash else { return }
            if let data = WorkspacePictureStore.shared.pictureData(
                for: workspaceId,
                matchingHash: pictureHash
            ) {
                image = NSImage(data: data)
            } else {
                image = nil
            }
            loadedHash = pictureHash
        }
    }
}
