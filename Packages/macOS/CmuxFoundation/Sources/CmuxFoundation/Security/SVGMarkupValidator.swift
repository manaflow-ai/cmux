public import Foundation

/// Validates SVG markup safety before the bytes are rendered as an image.
///
/// A pure-Foundation guard against hostile SVG: it rejects external DOCTYPEs and
/// entity declarations up front, then walks the markup with ``SVGSecurityInspector``
/// to block `<script>`/`<foreignObject>` elements, `on*` event-handler attributes,
/// `href`/`xlink:href` references that point outside the document, the
/// `javascript:`/`data:`/`http(s)`/`file`/`blob` value schemes, CSS `@import`, and
/// `xml-stylesheet` processing instructions. It reaches no app state and performs
/// no I/O, so a fresh value can be used per check.
public struct SVGMarkupValidator: Sendable {
    /// Creates a validator. The type is stateless; construct one per call site.
    public init() {}

    /// Returns `true` when `value`'s path extension is `svg` (case-insensitive).
    public func looksLikeSVGPath(_ value: String) -> Bool {
        (value as NSString).pathExtension.lowercased() == "svg"
    }

    /// Returns `true` when `data` decodes as UTF-8 SVG markup that contains only
    /// content safe to render: no external DOCTYPE/entity declarations and nothing
    /// the markup walk in ``SVGSecurityInspector`` flags as unsafe.
    public func isSafeSVG(data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else { return false }
        let lowered = text.lowercased()
        guard !lowered.contains("<!doctype"),
              !lowered.contains("<!entity") else {
            return false
        }

        let inspector = SVGSecurityInspector()
        return inspector.parse(data: data)
    }
}
