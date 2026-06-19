#if DEBUG
public import AppKit

extension NSWindow {
    /// DEBUG-only one-line summary of this window's number, identifier, and
    /// key/main state for the command-palette focus/overlay debug log.
    @MainActor
    public var commandPaletteWindowDebugSummary: String {
        let ident = identifier?.rawValue ?? "nil"
        return "num=\(windowNumber) ident=\(ident) key=\(isKeyWindow ? 1 : 0) main=\(isMainWindow ? 1 : 0)"
    }
}

extension Optional where Wrapped == NSWindow {
    /// DEBUG-only summary that renders `"nil"` for a missing window, otherwise
    /// delegates to ``AppKit/NSWindow/commandPaletteWindowDebugSummary``.
    @MainActor
    public var commandPaletteWindowDebugSummary: String {
        self?.commandPaletteWindowDebugSummary ?? "nil"
    }
}
#endif
