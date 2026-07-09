#if canImport(AppKit)
#if DEBUG
// Faithful-lift delta note: in the source god file these two helpers lived
// inside the `#if DEBUG` region of the `TerminalController: ControlDebugContext`
// conformance (Sources/TerminalController+ControlDebugContext.swift), so they
// compiled only in DEBUG. The `#if DEBUG` gate is preserved here to keep that
// behavior and to match this package's other debug-only sources (MenuBarExtraDebug,
// BackgroundDebug, SplitButtonLayoutDebug). The sole call site, the debug
// `screenshot` control command, is itself DEBUG-only.
public import AppKit

extension NSWindow {
    /// PNG bytes of the window captured via the window-server compositor
    /// (`CGWindowListCreateImage`), so the result includes effects the AppKit
    /// content view does not draw itself. Returns `nil` when the compositor
    /// cannot produce an image for the window. Used by the debug `screenshot`
    /// control command.
    public var compositedDebugPNGData: Data? {
        guard let cgImage = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            CGWindowID(windowNumber),
            [.boundsIgnoreFraming, .nominalResolution]
        ) else {
            return nil
        }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }

    /// PNG bytes of the window's content view rendered directly through AppKit
    /// (`cacheDisplay(in:to:)`), used as a fallback when the compositor capture
    /// is unavailable. Returns `nil` when the window has no content view or its
    /// bounds are empty. Used by the debug `screenshot` control command.
    public var appKitDebugPNGData: Data? {
        guard let contentView else {
            return nil
        }

        let bounds = contentView.bounds
        guard !bounds.isEmpty,
              let bitmap = contentView.bitmapImageRepForCachingDisplay(in: bounds) else {
            return nil
        }
        bitmap.size = bounds.size

        contentView.displayIfNeeded()
        contentView.cacheDisplay(in: bounds, to: bitmap)

        return bitmap.representation(using: .png, properties: [:])
    }
}
#endif
#endif
