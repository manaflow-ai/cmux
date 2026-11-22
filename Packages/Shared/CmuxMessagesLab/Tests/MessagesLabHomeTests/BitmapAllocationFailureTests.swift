import AppKit
import Testing
@testable import MessagesLabHome

/// Crash program: a row, tile or glyph bitmap that cannot be allocated (here a size no
/// context accepts) used to trap on `cgImage!`; it now yields no bitmap and the caller draws nothing.
@Suite struct BitmapAllocationFailureTests {
    @Test func anUnallocatableBitmapIsNilNotATrap() {
        let image = WideBitmap.make(size: CGSize(width: 1e9, height: 1e9), scale: 2, opaque: false) { _ in }
        #expect(image == nil)
    }
}
