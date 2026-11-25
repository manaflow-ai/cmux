public import CmuxNextDaemon
import Foundation

extension CloudLinkChange {
    /// The link change in a local daemon event, or nil.
    public init?(_ event: DaemonEvent) {
        guard let event = AppServerEvent(event), event.app == CloudLinkKey.app,
              let line = try? JSONEncoder().encode(event.payload), let change = Self.parse(appServerEvent: line) else { return nil }
        self = change
    }
}
