import Foundation


func noteAttachmentPayload(_ attachment: CmuxNoteAttachment) -> [String: Any] {
    [
        "kind": attachment.kind.rawValue,
        "workspace_anchor_id": attachment.workspaceAnchorId,
        "surface_anchor_id": (attachment.surfaceAnchorId as Any?) ?? NSNull(),
        "surface_kind": (attachment.surfaceKind as Any?) ?? NSNull(),
        "created_at": attachment.createdAt
    ]
}

func noteRecordPayload(note: CmuxNoteRecord, path: String) -> [String: Any] {
    [
        "id": note.id,
        "slug": note.slug,
        "title": note.title,
        "body_path": note.bodyPath,
        "path": path,
        "created_at": note.createdAt,
        "updated_at": note.updatedAt,
        "attachments": note.attachments.map(noteAttachmentPayload)
    ]
}

func noteFilePayload(path: String) -> [String: Any] {
    let url = URL(fileURLWithPath: path)
    let values = try? url.resourceValues(forKeys: [
        .isRegularFileKey,
        .fileSizeKey,
        .contentModificationDateKey
    ])
    return [
        "exists": values?.isRegularFile == true,
        "size_bytes": Int64(values?.fileSize ?? 0),
        "mtime": (values?.contentModificationDate ?? .distantPast).timeIntervalSince1970
    ]
}
