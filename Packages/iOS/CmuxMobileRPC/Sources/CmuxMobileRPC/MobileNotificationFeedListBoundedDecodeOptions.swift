import Foundation

struct MobileNotificationFeedListBoundedDecodeOptions: Sendable {
    let maxNotifications: Int
    let stringLimits: MobileNotificationFeedListStringLimits
}

func mobileNotificationFeedListBoundedDecodeOptions(
    from decoder: any Decoder
) throws -> MobileNotificationFeedListBoundedDecodeOptions {
    if let options = CodingUserInfoKey.mobileNotificationFeedListBoundedDecodeOptions
        .flatMap({ decoder.userInfo[$0] }) as? MobileNotificationFeedListBoundedDecodeOptions {
        return options
    }
    let context = DecodingError.Context(
        codingPath: decoder.codingPath,
        debugDescription: "Missing bounded notification feed decode options"
    )
    throw DecodingError.dataCorrupted(context)
}
