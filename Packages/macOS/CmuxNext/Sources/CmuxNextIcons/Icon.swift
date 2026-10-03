public import SwiftUI

/// A cmux icon drawn from the pack in the view's foreground style, or its SF
/// Symbol fallback. Style and accent come from the environment
/// (`.iconStyle(_:)`, `.iconAccent(_:)`).
public struct Icon: View {
    private let name: IconName
    private let size: CGFloat

    @Environment(\.iconStyle) private var style
    @Environment(\.iconAccent) private var accent
    @Environment(\.iconAccentColor) private var accentColor

    /// `size` is the side in points (`CGFloat.iconDefaultSize` when nil),
    /// never below `CGFloat.iconFloor`.
    public init(_ name: IconName, size: CGFloat? = nil) {
        self.name = name
        self.size = max(CGFloat.iconFloor, size ?? CGFloat.iconDefaultSize)
    }

    public var body: some View {
        let drawn = IconCatalog.bundled.style(style, for: name, size: size)
        Group {
            switch IconPack.bundled.resolve(name, style: drawn, accent: accent) {
            case .drawing(let layers):
                IconCanvas(layers: layers, grid: IconPack.bundled.grid, accentColor: accentColor ?? .accentColor)
            case .system(let symbol):
                Image(systemName: symbol)
                    .resizable()
                    .scaledToFit()
            }
        }
        .frame(width: size, height: size)
    }
}
