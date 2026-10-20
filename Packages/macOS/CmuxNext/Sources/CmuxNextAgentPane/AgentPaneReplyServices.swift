public import AppKit
public import Foundation

/// App-owned dependencies and held-site conversion shared by every agent pane.
@MainActor public final class AgentPaneReplyServices {
    private let sourceIcons: AgentPaneSourceIcons

    /// Uses the app's single bounded source-icon queue, including its cross-pane cache.
    /// - Parameter sourceIcons: The queue constructed at the app composition root.
    public init(sourceIcons: AgentPaneSourceIcons) { self.sourceIcons = sourceIcons }

    /// Gives a pane access to the app's queue without owning a separate budget.
    /// - Parameter links: The pane's reply-link dependencies.
    public func wire(_ links: AgentPaneReplyLinks) {
        links.favicon = { [sourceIcons] in await sourceIcons.result(at: $0) }
    }

    /// Whether two URLs name the same browser site.
    /// - Parameters:
    ///   - a: The first browser URL.
    ///   - b: The linked URL to compare.
    /// - Returns: Whether the scheme, hostname and port match.
    public func sameSite(_ a: URL, _ b: URL) -> Bool {
        a.scheme?.lowercased() == b.scheme?.lowercased() && a.host(percentEncoded: false)?.lowercased() == b.host(percentEncoded: false)?.lowercased()
            && a.port == b.port
    }

    /// Whether two URLs name the same page, ignoring fragments.
    /// - Parameters:
    ///   - a: The first browser URL.
    ///   - b: The linked URL to compare.
    /// - Returns: Whether the site, path and query match.
    public func samePage(_ a: URL, _ b: URL) -> Bool {
        sameSite(a, b) && a.path(percentEncoded: true) == b.path(percentEncoded: true) && a.query == b.query
    }

    /// Encodes an already-held browser favicon for a reply chip.
    /// - Parameter image: An image from the browser's existing favicon cache.
    /// - Returns: The image's PNG representation, when available.
    public func png(_ image: NSImage) -> Data? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }
}
