public import AppKit

extension NSView {
    /// Walks the superview chain (including `self`) and returns the nearest
    /// ancestor stamped with ``commandPaletteOverlayContainerIdentifier``.
    ///
    /// Used to decide whether a responder/view lives inside the command-palette
    /// overlay container.
    public var commandPaletteOverlayContainerAncestor: NSView? {
        var current: NSView? = self
        while let candidate = current {
            if candidate.identifier == commandPaletteOverlayContainerIdentifier {
                return candidate
            }
            current = candidate.superview
        }
        return nil
    }

    /// Whether this view has a command-palette overlay container ancestor
    /// (including itself).
    public var isInsideCommandPaletteOverlay: Bool {
        commandPaletteOverlayContainerAncestor != nil
    }

    /// Whether this view is an overlay container that is currently presented:
    /// visible (not hidden) and effectively opaque.
    ///
    /// The presented test matches the overlay's reveal animation, which fades
    /// `alphaValue` in/out; a near-zero alpha is treated as not presented.
    public var isCommandPaletteOverlayPresented: Bool {
        !isHidden && alphaValue > 0.001
    }
}

extension NSWindow {
    /// Searches this window's view hierarchy (depth-first from the content
    /// view's superview, falling back to the content view) for the command-palette
    /// overlay container.
    public var commandPaletteOverlayContainer: NSView? {
        guard let searchRoot = contentView?.superview ?? contentView else { return nil }
        var stack: [NSView] = [searchRoot]
        while let candidate = stack.popLast() {
            if candidate.identifier == commandPaletteOverlayContainerIdentifier {
                return candidate
            }
            stack.append(contentsOf: candidate.subviews)
        }
        return nil
    }

    /// Whether this window currently hosts a presented command-palette overlay
    /// (mounted, not hidden, and effectively opaque).
    public var isCommandPaletteOverlayPresented: Bool {
        guard let container = commandPaletteOverlayContainer else { return false }
        return container.isCommandPaletteOverlayPresented
    }
}
