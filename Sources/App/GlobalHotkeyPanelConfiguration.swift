import AppKit

@MainActor
enum GlobalHotkeyPanelConfiguration {
    static let windowIdentifier = "cmux.hotkeyPanel"

    static let styleMask: NSWindow.StyleMask = [
        .nonactivatingPanel,
        .titled,
        .resizable,
        .fullSizeContentView,
    ]

    static let collectionBehavior: NSWindow.CollectionBehavior = [
        .canJoinAllSpaces,
        .fullScreenAuxiliary,
        .transient,
        .ignoresCycle,
    ]

    static var windowLevel: NSWindow.Level {
        NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) - 2)
    }

    static func apply(to panel: NSPanel) {
        panel.level = windowLevel
        panel.collectionBehavior = collectionBehavior
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isExcludedFromWindowsMenu = true
        panel.animationBehavior = .utilityWindow
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = false
        panel.isMovable = true
        panel.isRestorable = false
        panel.isReleasedWhenClosed = false
    }
}
