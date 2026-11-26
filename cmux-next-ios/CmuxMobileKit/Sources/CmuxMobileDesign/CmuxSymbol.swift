import Foundation
#if canImport(SwiftUI)
import SwiftUI
#endif

/// cmux's own symbols: drawings from the icon pack (`design/icons/source`) as SF Symbols
/// templates in this module's asset catalog, so they take the text's size and weight like the
/// system symbols beside them in a menu.
public enum CmuxSymbol {
    /// Fork a chat (Fork Conversation…): the pack's `agent.fork`, the split arrow Claude and Codex
    /// draw for branching a chat, the drawing the Mac and the web show for the same rows.
    /// `Assets.xcassets/cmux.fork.symbolset`; ForkSymbolTests keeps it on the pack's path.
    public static let fork = "cmux.fork"

    /// The bundle whose asset catalog holds these symbols.
    public static var bundle: Bundle { .module }

    #if canImport(SwiftUI)
    /// `fork` as an image resource, for SwiftUI's `Menu(_:image:)`, `Button(_:image:)` and `Label(_:image:)`.
    public static var forkImage: ImageResource { ImageResource(name: fork, bundle: .module) }
    #endif
}
