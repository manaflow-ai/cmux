import CmuxLink
import CmuxMobileWire
import Foundation

/// One decoded record from a `MobileChannel`.
public enum MobileInbound: Sendable, Hashable {
    /// A `json` record: an envelope frame or a channel message object.
    case json(JSONValue)
    /// A binary record with its flags (terminal input, rd frames, file chunks).
    case binary(Data, RecordFlags)
    /// The link reported loss beyond what the sender retained.
    case gap
    /// The channel ended; last element.
    case closed(ChannelCloseReason)
}
