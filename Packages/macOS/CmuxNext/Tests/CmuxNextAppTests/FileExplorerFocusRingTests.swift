import AppKit
@testable import CmuxNextApp
import Foundation
import Testing

/// The Find section's search field shows the system focus ring: in the sidebar no rounded control
/// owns it, so the ring is the only sign of keyboard focus (an accessibility need, not a style).
@MainActor @Suite(.serialized)
struct FileExplorerFocusRingTests {
    @Test func theFindFieldShowsAFocusRing() {
        let view = FindSectionView(model: FindSectionModel(search: { _, _ in nil }), rootFolder: { URL(fileURLWithPath: "/tmp") },
                                   effects: NullFileExplorerEffects())
        #expect(view.field.focusRingType != .none)
    }
}
