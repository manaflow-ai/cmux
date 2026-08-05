import Foundation

struct MobileNotificationFeedListBoundedDecodeOptions: Sendable {
    let maxNotifications: Int
    let stringLimits: MobileNotificationFeedListStringLimits
}

// lint:allow free-function - internal package helper mobileNotificationFeedListBoundedDecodeOptions, preserving existing call sites during UI closeout.
func mobileNotificationFeedListBoundedDecodeOptions(
    from decoder: any Decoder
) throws -> MobileNotificationFeedListBoundedDecodeOptions {
    if let options = decoder.userInfo[.mobileNotificationFeedListBoundedDecodeOptions]
        as? MobileNotificationFeedListBoundedDecodeOptions {
        return options
    }
    let context = DecodingError.Context(
        codingPath: decoder.codingPath,
        debugDescription: "Missing bounded notification feed decode options"
    )
    throw DecodingError.dataCorrupted(context)
}
