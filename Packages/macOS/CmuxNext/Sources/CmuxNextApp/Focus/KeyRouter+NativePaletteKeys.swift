import AppKit
import CmuxNextActions

// Red commit stub (the regression tests before the fix): no web view guard yet. The next commit
// replaces it with the real step.
extension KeyRouter {
    nonisolated static let nativePaletteActions: Set<ActionID> = []

    static func webContentHasKeys(in window: NSWindow) -> Bool { false }

    func routesNativePaletteKey(_ event: NSEvent, in window: NSWindow?) -> Bool { false }
}
