import AppKit
import CmuxNextDesign

extension WorkspaceHoverCardView {
    /// Every text an embedded view shows, by its accessibility (a SwiftUI scene has no labels).
    /// Depth first, a parent before its children, children in order. An explicit stack, not a
    /// recursive local function: Swift 6.3.3's SendNonSendable pass crashed now and then on the
    /// local function's capture of the result (Release compile, CmuxNextSidebar).
    static func texts(in view: NSView) -> [String] {
        var out: [String] = []
        var pending: [Any] = [view]
        while let element = pending.popLast() {
            guard let object = element as? any NSAccessibilityProtocol else { continue }
            if let role = object.accessibilityRole(), role == .staticText,
               let value = object.accessibilityValue() as? String ?? object.accessibilityLabel(), !value.isEmpty {
                out.append(value)
            }
            // Reversed, so the first child pops first.
            pending.append(contentsOf: (object.accessibilityChildren() ?? []).reversed())
        }
        return out
    }

    /// Where a one-line fact cuts: a path or a branch in the middle (its end says which), a pull
    /// request at its tail ("#22231 Share one hover…": the number and the title's start read).
    static func truncation(_ fact: WorkspaceHoverCardContent.Fact) -> NSLineBreakMode {
        fact.kind == "pullRequest" ? .byTruncatingTail : .byTruncatingMiddle
    }

    /// A status entry's own icon: its stored image, its SF Symbol or its emoji; nil for none (or
    /// an asset not read yet), so the fact's icon draws.
    static func ownImage(_ fact: WorkspaceHoverCardContent.Fact) -> NSImage? {
        let size = NSSize(width: HoverCardRowView.iconSize, height: HoverCardRowView.iconSize)
        if let image = fact.image { return NSImage(cgImage: image.image, size: size) }
        guard let mark = fact.mark, !mark.isEmpty else { return nil }
        if let symbol = NSImage(systemSymbolName: mark, accessibilityDescription: nil) { return symbol }
        guard !mark.unicodeScalars.allSatisfy(\.isASCII) else { return nil }
        return NSImage(size: size, flipped: false) { rect in
            (mark as NSString).draw(in: rect, withAttributes: [.font: Typography.system(size: rect.height * 0.8)])
            return true
        }
    }

}
