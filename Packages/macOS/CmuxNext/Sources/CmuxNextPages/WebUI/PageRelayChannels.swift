/// The page relay channels of one ``WebUIHost``: one per daemon service and daemon
/// page id (`cmux.history` -> `history`), shared by every page tab of that id. The app's channel
/// type (`PageRelayChannel`, a daemon connection with the `page_relay` role) lives in the app
/// target, which knows the daemon; the host only keeps them, so no channel is a process-wide static.
/// The Chief editor's relay (`ChiefProfilePageRelay`, one per Chief owner, shared by Home and
/// Settings) is kept here the same way, keyed by its owner and its page.
///
/// Chrome keeps a WebUI's browser-side state on the objects of its profile, never in globals
/// (`WebUIControllerFactory` and the per-profile keyed services,
/// components/keyed_service/core/keyed_service.h); this is the host's keyed slot for the relays.
@MainActor
public final class PageRelayChannels {
    /// Which channel: the daemon service (or Chief owner) it talks to and the daemon page id (nil for
    /// a descriptor that names no daemon page; such a channel may call nothing).
    public struct Key: Hashable, Sendable {
        public let service: ObjectIdentifier
        public let page: String?

        public init(service: ObjectIdentifier, page: String?) {
            self.service = service
            self.page = page
        }
    }

    private var channels: [Key: AnyObject] = [:]

    public init() {}

    /// The channel of `key`, made by `make` the first time it is asked for.
    ///
    /// - Parameters:
    ///   - key: The service and daemon page id.
    ///   - make: Makes the channel; it runs once per key.
    /// - Returns: The key's one channel.
    public func channel<Channel: AnyObject>(for key: Key, make: () -> Channel) -> Channel {
        if let channel = channels[key] as? Channel { return channel }
        let channel = make()
        channels[key] = channel
        return channel
    }

    /// The channels made so far (each holds a daemon connection only while it is used).
    public var count: Int { channels.count }
}
