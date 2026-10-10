import AppKit

// cmux: Liquid Glass with a macOS 14 and 15 fallback (cmux-next supports
// macOS 14; plans/cmux-next/macos-floor.md). On macOS 26 and newer every
// surface is the system NSGlassEffectView / NSGlassEffectContainerView,
// configured exactly as before, so 26 and 27 draw the same pixels. Below 26
// the surface is an NSVisualEffectView with the same corner radius and content
// view, and the container is a plain view (glass shapes do not merge there).

/// A glass surface: the system glass view on macOS 26, a visual-effect
/// stand-in below. Same names as NSGlassEffectView, so call sites do not change.
@MainActor
protocol LabGlassSurface: NSView {
    var contentView: NSView? { get set }
    var cornerRadius: CGFloat { get set }
}

/// A glass container: the system container on macOS 26, a plain view below.
@MainActor
protocol LabGlassContainer: NSView {
    var contentView: NSView? { get set }
    var spacing: CGFloat { get set }
}

@available(macOS 26, *)
extension NSGlassEffectView: LabGlassSurface {}

@available(macOS 26, *)
extension NSGlassEffectContainerView: LabGlassContainer {}

/// Makes the glass views for the running macOS.
@MainActor
enum LabGlass {
    /// A regular-style glass surface (NSGlassEffectView on macOS 26 and newer).
    static func surface(frame: NSRect = .zero) -> any LabGlassSurface {
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView(frame: frame)
            glass.style = .regular
            return glass
        }
        return LegacyGlassView(frame: frame)
    }

    /// A glass container (NSGlassEffectContainerView on macOS 26 and newer).
    static func container() -> any LabGlassContainer {
        if #available(macOS 26, *) { return NSGlassEffectContainerView() }
        return LegacyGlassContainerView()
    }
}

/// macOS 14 and 15: a behind-window-content blur with the glass view's corner
/// radius; its content view fills it, as in NSGlassEffectView.
final class LegacyGlassView: NSVisualEffectView, LabGlassSurface {
    var contentView: NSView? {
        didSet {
            guard oldValue !== contentView else { return }
            oldValue?.removeFromSuperview()
            guard let contentView else { return }
            contentView.frame = bounds
            contentView.autoresizingMask = [.width, .height]
            addSubview(contentView)
        }
    }

    var cornerRadius: CGFloat = 0 {
        didSet {
            layer?.cornerRadius = cornerRadius
            layer?.masksToBounds = cornerRadius > 0
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        material = .popover
        blendingMode = .withinWindow
        state = .followsWindowActiveState
    }

    required init?(coder: NSCoder) { nil }
}

/// macOS 14 and 15: holds its content view at its own size; `spacing` is kept
/// only so call sites stay the same (shapes do not merge without system glass).
final class LegacyGlassContainerView: NSView, LabGlassContainer {
    var spacing: CGFloat = 0

    var contentView: NSView? {
        didSet {
            guard oldValue !== contentView else { return }
            oldValue?.removeFromSuperview()
            guard let contentView else { return }
            contentView.frame = bounds
            contentView.autoresizingMask = [.width, .height]
            addSubview(contentView)
        }
    }
}
