public import AppKit

public extension NSView {
    /// The command-palette overlay container found by walking this view's
    /// ancestor chain (including `self`), matching
    /// ``commandPaletteOverlayContainerIdentifier``. `nil` when no ancestor is
    /// the overlay container.
    var commandPaletteOverlayAncestor: NSView? {
        var current: NSView? = self
        while let candidate = current {
            if candidate.identifier == commandPaletteOverlayContainerIdentifier {
                return candidate
            }
            current = candidate.superview
        }
        return nil
    }

    /// Whether this view is inside (or is) the command-palette overlay container.
    var isInsideCommandPaletteOverlay: Bool {
        commandPaletteOverlayAncestor != nil
    }

    /// Whether this overlay container view is currently presented: not hidden
    /// and effectively opaque (`alphaValue > 0.001`). Call on the container view.
    var isCommandPaletteOverlayContainerPresented: Bool {
        !isHidden && alphaValue > 0.001
    }
}

public extension NSWindow {
    /// The command-palette overlay container in this window's view hierarchy,
    /// found by breadth-first search from the content view's superview (or the
    /// content view), matching ``commandPaletteOverlayContainerIdentifier``.
    var commandPaletteOverlayContainerView: NSView? {
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

    /// Whether the command-palette overlay is presented in this window: its
    /// container view exists and is not hidden and effectively opaque.
    var isCommandPaletteOverlayPresented: Bool {
        guard let container = commandPaletteOverlayContainerView else { return false }
        return container.isCommandPaletteOverlayContainerPresented
    }
}
