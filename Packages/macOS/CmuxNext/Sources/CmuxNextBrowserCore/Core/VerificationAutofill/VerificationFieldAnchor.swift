public import Foundation

/// Where a page's code field is, as fractions of the page's viewport, so the native suggestion can
/// sit under it at any zoom (``VerificationPageScripts/anchorScript``). Geometry only: it never
/// holds page text or a code.
public nonisolated struct VerificationFieldAnchor: Sendable, Hashable {
    /// The field's rect in viewport fractions, origin at the top left (0...1 when on screen).
    public let rect: CGRect

    /// - Parameter rect: The field's rect in viewport fractions, top-left origin.
    public init(rect: CGRect) {
        self.rect = rect
    }

    /// Reads the anchor script's result: nil for null, a non-string, bad JSON or an empty viewport.
    /// - Parameter value: The script's result as the engine returned it.
    public init?(scriptResult value: BrowserJSValue) {
        guard case .string(let text) = value,
              let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let x = (object["x"] as? NSNumber)?.doubleValue, let y = (object["y"] as? NSNumber)?.doubleValue,
              let width = (object["width"] as? NSNumber)?.doubleValue, let height = (object["height"] as? NSNumber)?.doubleValue,
              let viewportWidth = (object["viewportWidth"] as? NSNumber)?.doubleValue, viewportWidth > 0,
              let viewportHeight = (object["viewportHeight"] as? NSNumber)?.doubleValue, viewportHeight > 0,
              width > 0, height > 0
        else { return nil }
        rect = CGRect(x: x / viewportWidth, y: y / viewportHeight, width: width / viewportWidth, height: height / viewportHeight)
    }

    /// The field's rect in a page view of `size` points, top-left origin.
    /// - Parameter size: The page view's size.
    public func rect(in size: CGSize) -> CGRect {
        CGRect(x: rect.minX * size.width, y: rect.minY * size.height, width: rect.width * size.width, height: rect.height * size.height)
    }
}
