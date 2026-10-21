public import AppKit

/// The images a ``FindPillView`` draws. The caller passes them from `CmuxNextIcons`, which
/// this module does not depend on, so every surface hands over the same four icons.
public struct FindPillIcons {
    /// The magnifier before the field.
    public var search: NSImage
    /// The up chevron (previous match).
    public var previous: NSImage
    /// The down chevron (next match).
    public var next: NSImage
    /// The close cross.
    public var close: NSImage

    /// - Parameters:
    ///   - search: The magnifier before the field.
    ///   - previous: The up chevron.
    ///   - next: The down chevron.
    ///   - close: The close cross.
    public init(search: NSImage, previous: NSImage, next: NSImage, close: NSImage) {
        self.search = search
        self.previous = previous
        self.next = next
        self.close = close
    }
}
