import CoreGraphics
import Foundation

// Safari's address label rules: one short, single-line label per page, and
// a width cap so a long label never widens the toolbar.

extension TabsKitAddress {
    /// The capsule label for a page URL, as Safari shows it: the host without
    /// `www.`, a local file's name (`file:` has no host), otherwise the URL
    /// itself (`data:`, `about:`), which the capsule truncates.
    public static func displayLabel(for url: URL) -> String {
        if url.isFileURL {
            let name = url.lastPathComponent
            return name.isEmpty ? url.path : name
        }
        if let host = url.host(), !host.isEmpty {
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        return url.absoluteString
    }

    /// A local file page: the capsule shows the file name beside a document
    /// glyph and truncates in the middle, keeping the extension.
    public var isFile: Bool {
        if case .url(_, let editing, let search) = self { !search && editing.lowercased().hasPrefix("file:") } else { false }
    }
}

/// The collapsed pill hugs its label, up to the space between the expanded
/// side controls; a longer label truncates inside it.
enum CollapsedPill {
    /// The widest pill: the screen minus the side inset, the back control,
    /// the tabs circle and their gaps on each side (symmetric, as the pill is
    /// centered), never under two paddings plus 40 pt.
    static func maxWidth(screenWidth: CGFloat, sideInset: CGFloat, backWidth: CGFloat, control: CGFloat,
                         gap: CGFloat, padding: CGFloat) -> CGFloat {
        max(2 * padding + 40, screenWidth - 2 * (sideInset + max(backWidth, control) + gap))
    }

    /// The pill's width for a label measured at the expanded font size.
    static func width(labelWidth: CGFloat, scale: CGFloat, padding: CGFloat, maxWidth: CGFloat) -> CGFloat {
        min(labelWidth * scale + 2 * padding, maxWidth)
    }

    /// The label's unscaled width inside the pill (it is drawn at the expanded
    /// size, then scaled down).
    static func labelWidth(labelWidth: CGFloat, scale: CGFloat, padding: CGFloat, maxWidth: CGFloat) -> CGFloat {
        guard scale > 0 else { return 0 }
        return min(labelWidth, max(0, (maxWidth - 2 * padding) / scale))
    }
}
