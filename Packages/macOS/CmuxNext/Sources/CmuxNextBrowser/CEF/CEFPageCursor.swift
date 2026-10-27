import AppKit

/// A page's cursor as the Chromium Host reports it (`CMUX_SHIM_CURSOR`; task 045 of
/// plans/cmux-next/chrome-parity/p01-process.md): a `cef_cursor_type_t`, or a CSS cursor image.
/// ``ChromiumHostPageView`` shows it. The mapping is plain data so a headless test can check it;
/// only ``makeCursor()`` touches `NSCursor`. Chrome's app shim turns the same `ui::Cursor` into an
/// `NSCursor` (ui/base/cocoa/cursor_utils.mm: `GetNativeCursor`, `CreateCustomCursor`), with
/// images of its own for the cursors macOS has no public one for (wait, help, move); those show the
/// arrow here.
nonisolated enum CEFPageCursor: Equatable, Sendable {
    /// A built-in cursor: a `cef_cursor_type_t` value (include/internal/cef_types.h).
    case builtIn(Int32)
    /// A CSS cursor image: PNG bytes, image pixels per point, and the hotspot in image pixels
    /// from the top left.
    case custom(png: Data, scale: Double, hotspotX: Int32, hotspotY: Int32)

    /// The arrow (`CT_POINTER`): a page that set no cursor yet.
    static let arrow = CEFPageCursor.builtIn(0)

    /// `CT_CUSTOM`.
    static let customType: Int64 = 45

    /// A CURSOR event's fields: `type` (a), `scaleMilli` (request), `hotspot` (b: x in the low
    /// 32 bits, y in the high 32) and the image as base64 PNG (s1). A custom cursor whose image
    /// does not decode shows the arrow, as the shim sends one it cannot encode.
    init(type: Int64, scaleMilli: Int32, hotspot: Int64, pngBase64: String) {
        guard type == Self.customType else {
            self = .builtIn(Int32(clamping: type))
            return
        }
        guard scaleMilli > 0, let png = Data(base64Encoded: pngBase64), !png.isEmpty else {
            self = .arrow
            return
        }
        self = .custom(png: png, scale: Double(scaleMilli) / 1_000, hotspotX: Int32(truncatingIfNeeded: hotspot),
                       hotspotY: Int32(truncatingIfNeeded: hotspot >> 32))
    }

    /// The CSS name of the cursor ("custom" for an image; "default" for a value past the table).
    var cssName: String {
        switch self {
        case .custom: "custom"
        case .builtIn(let type): Self.cssNames.indices.contains(Int(type)) ? Self.cssNames[Int(type)] : "default"
        }
    }

    /// CSS cursor names in `cef_cursor_type_t` order, CT_POINTER (0) to CT_DND_LINK (49); the
    /// panning and drag cursors take the name of the cursor they show (cmux-remote-browser-host's
    /// page.rs keeps the same table).
    static let cssNames: [String] = [
        "default", "crosshair", "pointer", "text", "wait", "help",
        "e-resize", "n-resize", "ne-resize", "nw-resize", "s-resize", "se-resize", "sw-resize", "w-resize",
        "ns-resize", "ew-resize", "nesw-resize", "nwse-resize", "col-resize", "row-resize",
        "all-scroll", "e-resize", "n-resize", "ne-resize", "nw-resize", "s-resize", "se-resize", "sw-resize",
        "w-resize", "move", "vertical-text", "cell", "context-menu", "alias", "progress", "no-drop", "copy",
        "none", "not-allowed", "zoom-in", "zoom-out", "grab", "grabbing", "ns-resize", "ew-resize",
        "custom", "no-drop", "move", "copy", "alias",
    ]

    /// The `NSCursor` that shows this cursor. Main thread: AppKit makes cursors there.
    @MainActor func makeCursor() -> NSCursor {
        switch self {
        case .custom(let png, let scale, let x, let y):
            Self.imageCursor(png: png, scale: scale, hotspotX: x, hotspotY: y) ?? .arrow
        case .builtIn:
            Self.builtInCursor(cssName)
        }
    }

    @MainActor private static func builtInCursor(_ name: String) -> NSCursor {
        switch name {
        case "crosshair", "cell": .crosshair
        case "pointer": .pointingHand
        case "text": .iBeam
        case "vertical-text": .iBeamCursorForVerticalLayout
        case "e-resize": .resizeRight
        case "w-resize": .resizeLeft
        case "n-resize": .resizeUp
        case "s-resize": .resizeDown
        case "ew-resize": .resizeLeftRight
        case "ns-resize": .resizeUpDown
        case "col-resize": columnResize
        case "row-resize": rowResize
        case "ne-resize", "sw-resize", "nesw-resize", "nw-resize", "se-resize", "nwse-resize": diagonalResize(name)
        case "context-menu": .contextualMenu
        case "alias": .dragLink
        case "copy": .dragCopy
        case "no-drop", "not-allowed": .operationNotAllowed
        case "grab": .openHand
        case "grabbing": .closedHand
        case "zoom-in", "zoom-out": zoom(in: name == "zoom-in")
        case "none": hidden
        default: .arrow
        }
    }

    @MainActor private static var columnResize: NSCursor {
        if #available(macOS 15, *) { return .columnResize }
        return .resizeLeftRight
    }

    @MainActor private static var rowResize: NSCursor {
        if #available(macOS 15, *) { return .rowResize }
        return .resizeUpDown
    }

    /// macOS 15's window-corner cursors; the arrow before (no public diagonal cursor).
    @MainActor private static func diagonalResize(_ name: String) -> NSCursor {
        guard #available(macOS 15, *) else { return .arrow }
        let rising = name == "ne-resize" || name == "sw-resize" || name == "nesw-resize"
        return .frameResize(position: rising ? .topRight : .topLeft, directions: .all)
    }

    @MainActor private static func zoom(in zoomIn: Bool) -> NSCursor {
        guard #available(macOS 15, *) else { return .arrow }
        return zoomIn ? .zoomIn : .zoomOut
    }

    /// CSS `cursor: none`: a cursor with nothing to draw.
    @MainActor private static let hidden = NSCursor(image: NSImage(size: NSSize(width: 1, height: 1)), hotSpot: .zero)

    /// An image cursor sized in points (pixels / scale), its hotspot too, as Chrome's
    /// `CreateCustomCursor`; nil when the PNG does not decode.
    @MainActor private static func imageCursor(png: Data, scale: Double, hotspotX: Int32, hotspotY: Int32) -> NSCursor? {
        guard let image = NSImage(data: png), let rep = image.representations.first,
              rep.pixelsWide > 0, rep.pixelsHigh > 0, scale > 0 else { return nil }
        image.size = NSSize(width: Double(rep.pixelsWide) / scale, height: Double(rep.pixelsHigh) / scale)
        return NSCursor(image: image, hotSpot: NSPoint(x: Double(hotspotX) / scale, y: Double(hotspotY) / scale))
    }
}
