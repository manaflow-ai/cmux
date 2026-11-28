import CCmuxScreenKit
import CoreGraphics

// The screen viewer's rules are Rust (cmux-rd-core `screen_kit`, the C ABI in
// CCmuxScreenKit); the app links them: the Mac through CCmuxAppFFI, iOS
// through CmuxMobileLinkFFI.

/// Owns one Rust handle; a copy of the struct holding it shares the state
/// (none is copied: each view keeps one).
final class ScreenKitHandle {
    let raw: OpaquePointer
    private let free: (OpaquePointer) -> Void

    /// `raw` from a `cmux_screen_*_new`, which never returns NULL (Rust
    /// aborts on allocation failure).
    init(_ raw: OpaquePointer, free: @escaping (OpaquePointer) -> Void) {
        self.raw = raw
        self.free = free
    }

    deinit { free(raw) }
}

// Conversions between CoreGraphics and the C ABI's plain structs.
package extension CmuxScreenPoint {
    init(_ point: CGPoint) { self.init(x: point.x, y: point.y) }
}

package extension CmuxScreenSize {
    init(_ size: CGSize) { self.init(width: size.width, height: size.height) }
}

package extension CmuxScreenRect {
    init(_ rect: CGRect) { self.init(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height) }
}

package extension CGPoint {
    init(_ point: CmuxScreenPoint) { self.init(x: point.x, y: point.y) }
}

package extension CGSize {
    init(_ size: CmuxScreenSize) { self.init(width: size.width, height: size.height) }
}

package extension CGRect {
    init(_ rect: CmuxScreenRect) { self.init(x: rect.x, y: rect.y, width: rect.width, height: rect.height) }
}
