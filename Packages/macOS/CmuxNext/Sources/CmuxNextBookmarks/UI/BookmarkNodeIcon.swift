import AppKit
import CmuxNextDesign
import CmuxNextIcons
import SwiftUI

/// A manager page row's icon: a bookmark's site icon; a folder's own icon
/// (`bookmark-icon-v1`), an emoji or stored image as is or a symbol in the
/// row's secondary color; else the generic folder or page icon, which also
/// stands in while a site icon or a stored folder icon loads.
struct BookmarkNodeIcon: View {
    let node: BookmarkNode
    let source: (any BookmarkManagerSource)?
    let color: Color

    static let side: CGFloat = 13

    var body: some View {
        if let image = source?.favicon(for: node) {
            Image(decorative: image, scale: 1).resizable().interpolation(.high).frame(width: Self.side, height: Self.side)
        } else if let symbol = Self.symbol(of: node) {
            Icon(symbol: symbol, size: Self.side).foregroundStyle(color)
        } else {
            Icon(node.isFolder ? .folder : .browser, size: Self.side).foregroundStyle(color)
        }
    }

    /// A folder's SF Symbol icon, when this Mac draws it.
    static func symbol(of node: BookmarkNode) -> String? {
        guard node.isFolder, case .symbol(let name)? = IconValue(wire: node.icon),
              NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil else { return nil }
        return name
    }
}

/// Set Icon and, when the folder has one, Remove Icon in a folder's
/// right-click menu on the manager page, while the host can set folder icons.
struct BookmarkFolderIconMenuItems: View {
    let node: BookmarkNode
    let source: (any BookmarkManagerSource)?

    var body: some View {
        if let source, source.canSetFolderIcons {
            Button(BookmarkStrings.setIcon) { source.setIcon(of: node) }
            if node.icon != nil { Button(BookmarkStrings.removeIcon) { source.removeIcon(of: node) } }
        }
    }
}
