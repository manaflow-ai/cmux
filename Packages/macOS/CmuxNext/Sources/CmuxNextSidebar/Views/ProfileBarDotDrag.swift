import AppKit

/// One space dot drag in the footer (`ProfileBarView+DotDrag`): while it runs, each visible space's dot
/// is its own layer, so the dragged one follows the pointer and the others spring to the order a
/// drop would give; the bar's drawn marks stay hidden until the dots land.
@MainActor
final class ProfileBarDotDrag {
    /// The dragged space's index in the model's order.
    let from: Int
    /// The order these layer indices belong to when the drag starts.
    let profileIDs: [ProfileKey]
    /// Where the pointer grabbed the dot, from its slot's middle.
    let grab: CGFloat
    /// Holds the dots' layers, above the bar's marks.
    let container: CALayer
    /// Only visible dots need a layer. Each keeps its index in the full profile order.
    let dots: [Int: CALayer]
    /// The dragged dot's index if it dropped now (`from`: no move).
    var target: Int
    /// The pointer is over the footer band: a release there drops the dot.
    var overBand = true
    /// The pointer is outside the window: a release there opens the space in a new window.
    var outsideWindow = false
    /// Released: the dots are landing; the drag takes no more pointer moves.
    var landing = false

    init(from: Int, profileIDs: [ProfileKey], grab: CGFloat, container: CALayer, dots: [Int: CALayer]) {
        self.from = from
        self.profileIDs = profileIDs
        self.grab = grab
        self.container = container
        self.dots = dots
        target = from
    }

    /// `items` with the element at `from` moved to `target`.
    static func order<T>(_ items: [T], moving from: Int, to target: Int) -> [T] {
        guard items.indices.contains(from), items.indices.contains(target) else { return items }
        var items = items
        items.insert(items.remove(at: from), at: target)
        return items
    }
}
