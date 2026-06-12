import AppKit

/// Per-workspace picture (iMessage-style avatar) mutations. The image bytes live
/// on disk in `WorkspacePictureStore`; the workspace only carries the small
/// `@Published` content hash, declared in `Workspace.swift`.
extension Workspace {
    /// Set this workspace's picture from an image, persisting the downscaled PNG
    /// via `WorkspacePictureStore` and publishing the new content hash. Returns
    /// `false` when the image can't be encoded. The `@Published` hash change is
    /// what drives the sidebar avatar and the mobile-list push.
    @discardableResult
    func setPicture(_ image: NSImage) -> Bool {
        guard let hash = WorkspacePictureStore.shared.setPicture(image, for: id) else {
            return false
        }
        pictureHash = hash
        return true
    }

    /// Remove this workspace's picture from disk and clear the published hash.
    func clearPicture() {
        WorkspacePictureStore.shared.removePicture(for: id)
        pictureHash = nil
    }

    /// Re-derive the published picture hash from disk (used on restore so a
    /// persisted hash that no longer has a backing file falls back to no avatar).
    func reloadPictureHashFromStore() {
        WorkspacePictureStore.shared.invalidateCache(for: id)
        pictureHash = WorkspacePictureStore.shared.pictureHash(for: id)
    }

    /// Restore-time picture adoption. The picture file is named by workspace id,
    /// but restore rebuilds the workspace under a fresh UUID, so re-home the
    /// original id's picture onto the new id. Falls back to re-deriving from disk
    /// so a snapshot hash with no backing file resolves to no avatar instead of a
    /// dangling hash.
    func restorePicture(fromSnapshotWorkspaceId originalWorkspaceId: UUID?) {
        if let originalWorkspaceId,
           let migratedHash = WorkspacePictureStore.shared.migratePicture(
               from: originalWorkspaceId,
               to: id
           ) {
            pictureHash = migratedHash
        } else {
            reloadPictureHashFromStore()
        }
    }
}
