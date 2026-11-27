import AppKit
import Testing

/// The shot helper the server surfaces' contact sheets share (Add Device, Join Consent, the Machines
/// section). The Add Machine card's own states are in the webviews gallery
/// (webviews/src/pages/server-cards/add-machine/addMachine.gallery.tsx) since it moved to React.
@MainActor enum AddMachineShotsTests {
    static func render(_ view: NSView) throws -> NSImage {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        let size = view.fittingSize
        window.setContentSize(NSSize(width: max(size.width, 320), height: max(size.height, 120)))
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        window.close()
        return image
    }
}
