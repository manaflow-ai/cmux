public import Foundation

/// A page's request for a capability that needs the user's consent.
public struct BrowserPagePermissionRequest: Equatable, Hashable, Sendable {
    /// The capabilities a page can request.
    public enum Kind: Equatable, Hashable, Sendable {
        /// Camera capture.
        case camera
        /// Microphone capture.
        case microphone
        /// Screen or window capture.
        case screenCapture
        /// Location.
        case geolocation
        /// Web notifications.
        case notifications
        /// Clipboard reading.
        case clipboardRead
        /// MIDI system-exclusive access.
        case midiSysex
        /// Any other permission, by its engine name.
        case other(String)
    }

    /// The capabilities requested together (for example camera and microphone).
    public var kinds: [Kind]
    /// The origin asking.
    public var origin: URL?

    /// Creates a permission request.
    /// - Parameters:
    ///   - kinds: The capabilities requested.
    ///   - origin: The requesting origin.
    public init(kinds: [Kind], origin: URL?) {
        self.kinds = kinds
        self.origin = origin
    }
}
