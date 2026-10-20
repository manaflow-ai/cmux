import Foundation

struct MobileNotificationFeedListBoundedItem: Decodable {
    let item: MobileNotificationFeedListItem?

    enum CodingKeys: String, CodingKey {
        case id
        case workspaceID = "workspace_id"
        case surfaceID = "surface_id"
        case title
        case subtitle
        case body
        case createdAt = "created_at"
        case isRead = "is_read"
        case retargetsToLiveSurfaceOwner = "retargets_to_live_surface_owner"
        case workspaceTitle = "workspace_title"
        case surfaceTitle = "surface_title"
    }

    init(from decoder: any Decoder) throws {
        let options = try mobileNotificationFeedListBoundedDecodeOptions(from: decoder)
        let limits = options.stringLimits
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let surfaceID = try container.decodeIfPresent(String.self, forKey: .surfaceID)
        guard let id = try mobileNotificationFeedListIdentityString(
            from: container,
            forKey: .id,
            limitedToUTF8Bytes: limits.identifierByteLimit
        ),
            let workspaceID = try mobileNotificationFeedListIdentityString(
                from: container,
                forKey: .workspaceID,
                limitedToUTF8Bytes: limits.identifierByteLimit
            ),
            (surfaceID?.utf8.count ?? 0) <= limits.identifierByteLimit else {
            item = nil
            return
        }
        item = MobileNotificationFeedListItem(
            id: id,
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            title: try mobileNotificationFeedListString(
                from: container,
                forKey: .title,
                limitedToUTF8Bytes: limits.titleByteLimit
            ),
            subtitle: try mobileNotificationFeedListOptionalString(
                from: container,
                forKey: .subtitle,
                limitedToUTF8Bytes: limits.subtitleByteLimit
            ),
            body: try mobileNotificationFeedListString(
                from: container,
                forKey: .body,
                limitedToUTF8Bytes: limits.bodyByteLimit
            ),
            createdAt: Date(timeIntervalSince1970: try container.decode(Double.self, forKey: .createdAt)),
            isRead: try container.decode(Bool.self, forKey: .isRead),
            retargetsToLiveSurfaceOwner: try container.decodeIfPresent(
                Bool.self,
                forKey: .retargetsToLiveSurfaceOwner
            ) ?? false,
            workspaceTitle: try mobileNotificationFeedListOptionalString(
                from: container,
                forKey: .workspaceTitle,
                limitedToUTF8Bytes: limits.metadataByteLimit
            ),
            surfaceTitle: try mobileNotificationFeedListOptionalString(
                from: container,
                forKey: .surfaceTitle,
                limitedToUTF8Bytes: limits.metadataByteLimit
            )
        )
    }
}

private func mobileNotificationFeedListIdentityString(
    from container: KeyedDecodingContainer<MobileNotificationFeedListBoundedItem.CodingKeys>,
    forKey key: MobileNotificationFeedListBoundedItem.CodingKeys,
    limitedToUTF8Bytes maxBytes: Int
) throws -> String? {
    let value = try container.decode(String.self, forKey: key)
    guard value.utf8.count <= maxBytes else { return nil }
    return value
}

private func mobileNotificationFeedListString(
    from container: KeyedDecodingContainer<MobileNotificationFeedListBoundedItem.CodingKeys>,
    forKey key: MobileNotificationFeedListBoundedItem.CodingKeys,
    limitedToUTF8Bytes maxBytes: Int
) throws -> String {
    try mobileNotificationFeedListString(
        container.decode(String.self, forKey: key),
        limitedToUTF8Bytes: maxBytes
    )
}

private func mobileNotificationFeedListOptionalString(
    from container: KeyedDecodingContainer<MobileNotificationFeedListBoundedItem.CodingKeys>,
    forKey key: MobileNotificationFeedListBoundedItem.CodingKeys,
    limitedToUTF8Bytes maxBytes: Int
) throws -> String? {
    guard let value = try container.decodeIfPresent(String.self, forKey: key) else {
        return nil
    }
    return mobileNotificationFeedListString(value, limitedToUTF8Bytes: maxBytes)
}

private func mobileNotificationFeedListString(_ value: String, limitedToUTF8Bytes maxBytes: Int) -> String {
    guard maxBytes >= 0, value.utf8.count > maxBytes else { return value }
    var byteCount = 0
    var endIndex = value.startIndex
    while endIndex < value.endIndex {
        let nextIndex = value.index(after: endIndex)
        let characterByteCount = value[endIndex..<nextIndex].utf8.count
        guard byteCount + characterByteCount <= maxBytes else { break }
        byteCount += characterByteCount
        endIndex = nextIndex
    }
    return String(value[..<endIndex])
}
