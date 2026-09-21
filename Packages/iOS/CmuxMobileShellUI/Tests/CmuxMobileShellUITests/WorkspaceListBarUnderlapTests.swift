#if os(iOS)
import SwiftUI
import Testing
@testable import CmuxMobileShellUI

/// The workspace list's UIKit table is reused while a terminal or task
/// composer owns the keyboard. The table must keep its full-screen underlap;
/// otherwise SwiftUI can leave it clipped at the keyboard's old top edge after
/// the keyboard is dismissed.
struct WorkspaceListBarUnderlapTests {
    @Test func underlapIgnoresKeyboardSafeArea() {
        #expect(
            WorkspaceListBarUnderlap.ignoredSafeAreaRegions.contains(.keyboard),
            "The workspace table must not retain a keyboard-sized frame after a keyboard transition."
        )
    }
}
#endif
