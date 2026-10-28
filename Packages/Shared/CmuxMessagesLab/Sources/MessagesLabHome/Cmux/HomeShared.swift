// cmux: immutable SDK objects the row threads share, without an unchecked class each. Not a vendored file.
import AppKit
import CoreGraphics
import CoreText

/// cmux: a type that is not `Sendable` but whose values the transcript's
/// measure and render threads may share: Core Graphics images, Core Text lines, immutable
/// strings and attributed strings, the port's `UIImage` (all its stored properties are lets),
/// and values made only of them. Each is immutable once made and safe to read from any thread
/// (Core Text Programming Guide, "Thread Safety"; Chromium shares immutable `SkImage` and
/// `SkTextBlob` across raster threads the same way, cc/paint/paint_image.h). Never a
/// CTTypesetter, a mutable string or a builder object. Every conformance is declared in this file,
/// never beside its type, so a new one shows in review here. MessagesLabSidebar has the same rule
/// (`SidebarShareable`).
protocol HomeShareable {}

/// cmux: a ``HomeShareable`` value inside a checked `Sendable` type or lock
/// state. The module's one unchecked conformance for shared SDK objects; the caches, layouts and
/// stores that hold such values are checked `Sendable` (crash ratchet: MessagesLabHome unchecked).
// crash-allow: Value is HomeShareable, immutable once made and safe to read from any thread (see HomeShareable)
struct HomeShared<Value: HomeShareable>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

extension CGImage: HomeShareable {}
extension CTLine: HomeShareable {}
/// Made from a string and never mutated after (a mutable string is copied into one first).
extension NSString: HomeShareable {}
/// Built once (an `NSMutableAttributedString` is stored only after it is finished) and only read.
extension NSAttributedString: HomeShareable {}
/// The AppKit port's image: a CGImage, a scale and a symbol source, all lets.
extension UIImage: HomeShareable {}
/// A laid-out Markdown line: its attributed string and CTLine, read by the draw.
extension MDFrag: HomeShareable {}
/// A Markdown box; an image box holds its CGImage.
extension MDBox: HomeShareable {}
/// A Markdown layout's lines and boxes, drawn from any thread.
extension MarkdownLayout.Drawn: HomeShareable {}
/// A laid-out Markdown block as the layout cache shares it (lines, boxes and Sendable values).
extension MarkdownLayoutEngine.LaidBlock: HomeShareable {}
extension Array: HomeShareable where Element: HomeShareable {}
extension Optional: HomeShareable where Wrapped: HomeShareable {}
