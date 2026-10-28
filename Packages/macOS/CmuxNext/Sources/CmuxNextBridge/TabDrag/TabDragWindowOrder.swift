public import AppKit

/// The z-order of a drag's content windows, read from the window server once per drag instead of
/// on every hit test and every frame. It is read again when what changes an order changes: a content
/// window opens or closes (the set the caller passes), the key or main window changes (a window came
/// to the front), or a window is shown, hidden, miniaturized or restored, or changes occlusion. Those
/// are AppKit's local state, read without the window server; frames are read live from the windows,
/// so a window that moves or resizes needs no new read.
public final class TabDragWindowOrder {
    /// Window server reads (`NSApp.orderedWindows`), for the drag's work budget.
    public private(set) var reads = 0
    private struct Signature: Equatable {
        var windows: [ObjectIdentifier]
        var key: ObjectIdentifier?
        var main: ObjectIdentifier?
        var shown: [Bool]
    }

    private var signature: Signature?
    private var order: [ObjectIdentifier] = []

    public init() {}

    /// `windows` (the content windows), front to back; one that is ordered out is left out.
    public func frontToBack(_ windows: [NSWindow]) -> [NSWindow] {
        let now = Signature(windows: windows.map(ObjectIdentifier.init), key: NSApp.keyWindow.map(ObjectIdentifier.init),
                            main: NSApp.mainWindow.map(ObjectIdentifier.init),
                            shown: windows.map { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) })
        if now != signature {
            reads += 1
            signature = now
            let ids = Set(now.windows)
            order = NSApp.orderedWindows.map(ObjectIdentifier.init).filter(ids.contains)
        }
        let byID = Dictionary(windows.map { (ObjectIdentifier($0), $0) }, uniquingKeysWith: { first, _ in first })
        return order.compactMap { byID[$0] }
    }
}
