import AppKit
@testable import CmuxNextSidebar
import CmuxNextDesign
import Testing

/// The sidebar resize band stays hit-testable while its line follows Claude Code's quiet-at-rest
/// behavior. Hover and an active drag are the only transient states that reveal the line when the
/// configured resting border is off.
@MainActor
struct SidebarResizeHandleLineTests {
    func withFlatChrome<T>(_ body: () throws -> T) rethrows -> T {
        let design = DesignSettings.shared
        let savedStyle = design.chromeStyle
        design.chromeStyle = .flat
        let store = TunableStore.shared
        store.register([CornerFlush.tunable.descriptor, ChromeTunables.mainPaneCurved.descriptor])
        if !store.isActive { store.activate(file: nil) }
        let savedFlush = store.set(CornerFlush.tunable.key, nil)
        let savedCurved = store.set(ChromeTunables.mainPaneCurved.key, nil)
        defer {
            _ = store.set(CornerFlush.tunable.key, savedFlush)
            _ = store.set(ChromeTunables.mainPaneCurved.key, savedCurved)
            design.chromeStyle = savedStyle
        }
        return try body()
    }

    @Test func lineIsHiddenAtRestAndAppearsOnHover() {
        withFlatChrome {
            let handle = SidebarResizeHandle(frame: .zero)
            handle.restingLineWidth = 0

            #expect(!handle.isLineVisible)
            handle.setHovered(true)
            #expect(handle.isLineVisible)
            handle.setHovered(false)
            #expect(!handle.isLineVisible)
        }
    }

    @Test func draggingKeepsTheLineVisibleUntilRelease() throws {
        try withFlatChrome {
            let handle = SidebarResizeHandle(frame: CGRect(x: 0, y: 0, width: 8, height: 100))
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 100, height: 100),
                                  styleMask: [.titled], backing: .buffered, defer: true)
            defer { window.close() }
            window.contentView?.addSubview(handle)
            let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 4, y: 50),
                                                       modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                                       context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: CGPoint(x: 4, y: 50),
                                                     modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                                     context: nil, eventNumber: 0, clickCount: 1, pressure: 0))

            handle.mouseDown(with: down)
            #expect(handle.isLineVisible)
            handle.mouseUp(with: up)
            #expect(!handle.isLineVisible)
        }
    }
}
