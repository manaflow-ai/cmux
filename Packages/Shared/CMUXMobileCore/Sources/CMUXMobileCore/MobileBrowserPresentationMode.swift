import Foundation

/// The rendering path used for a Mac browser panel on a phone.
public enum MobileBrowserPresentationMode: String, Codable, Equatable, Sendable {
    /// The Mac renders the page and sends frames to the phone.
    case stream
    /// The phone loads the page in its own WebKit instance.
    case local
}
