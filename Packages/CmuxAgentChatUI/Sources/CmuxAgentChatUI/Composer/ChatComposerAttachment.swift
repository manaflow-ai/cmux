import CmuxAgentChat
import Foundation
import SwiftUI

/// An image the user staged in the composer, ready to send: the encoded
/// payload plus the thumbnail shown in the attachment strip.
public struct ChatComposerAttachment: Identifiable {
    /// Local identity for the thumbnail strip.
    public let id: String

    /// The encoded image payload that will be sent.
    public let data: Data

    /// The encoding of ``data``.
    public let format: ChatOutboundAttachment.Format

    #if os(iOS)
    /// The strip thumbnail rendered from the staged image.
    public let thumbnail: Image

    /// Creates a staged attachment.
    ///
    /// - Parameters:
    ///   - id: Local identity for the strip.
    ///   - data: Encoded image payload.
    ///   - format: Encoding of `data`.
    ///   - thumbnail: Strip thumbnail.
    public init(id: String, data: Data, format: ChatOutboundAttachment.Format, thumbnail: Image) {
        self.id = id
        self.data = data
        self.format = format
        self.thumbnail = thumbnail
    }
    #else
    /// Creates a staged attachment.
    ///
    /// - Parameters:
    ///   - id: Local identity for the strip.
    ///   - data: Encoded image payload.
    ///   - format: Encoding of `data`.
    public init(id: String, data: Data, format: ChatOutboundAttachment.Format) {
        self.id = id
        self.data = data
        self.format = format
    }
    #endif

    /// The wire attachment this staged item sends.
    public var outbound: ChatOutboundAttachment {
        ChatOutboundAttachment(data: data, format: format)
    }
}
