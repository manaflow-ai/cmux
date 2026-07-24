#if canImport(AppKit)

public import AppKit
public import Observation

/// Holds the live ``AboutTitlebarDebugOptions`` for each ``AboutWindowKind`` and
/// applies them to matching open windows.
///
/// This is the single writer of the debug options. Editing ``aboutOptions``
/// (directly or via ``update(_:for:)``) immediately reapplies the new treatment
/// to any open window with the matching identifier, preserving the original
/// `didSet`-driven behavior. Window decoration is delegated to an injected
/// ``WindowDecorating`` seam rather than reaching into the app delegate.
@MainActor
@Observable
public final class AboutTitlebarDebugStore {
    /// The current options for the About window. Setting this reapplies them to
    /// every open About window.
    public var aboutOptions = AboutTitlebarDebugOptions.defaults(for: .about) {
        didSet { applyToOpenWindows(for: .about) }
    }

    @ObservationIgnored
    private weak var decorator: (any WindowDecorating)?

    /// Creates a store.
    ///
    /// - Parameter decorator: The seam used to apply standard window chrome after
    ///   a debug option change. Held weakly because the app-side conformer
    ///   (`AppDelegate`) is a singleton that also owns this store, so a strong
    ///   reference would form a retain cycle.
    public init(decorator: (any WindowDecorating)?) {
        self.decorator = decorator
    }

    /// Returns the current options for a window kind.
    public func options(for kind: AboutWindowKind) -> AboutTitlebarDebugOptions {
        switch kind {
        case .about:
            return aboutOptions
        }
    }

    /// Replaces the current options for a window kind.
    public func update(_ newValue: AboutTitlebarDebugOptions, for kind: AboutWindowKind) {
        switch kind {
        case .about:
            aboutOptions = newValue
        }
    }

    /// Resets a window kind to its non-overriding defaults.
    public func reset(_ kind: AboutWindowKind) {
        update(AboutTitlebarDebugOptions.defaults(for: kind), for: kind)
    }

    /// Reapplies the current options to every open window of the given kind.
    ///
    /// A nil `NSApp` (no running application, e.g. a headless unit-test process)
    /// is a no-op; in the running app `NSApp` is always present, so this is
    /// behavior-preserving.
    public func applyToOpenWindows(for kind: AboutWindowKind) {
        guard let app = NSApp else { return }
        for window in app.windows where window.identifier?.rawValue == kind.windowIdentifier {
            apply(options(for: kind), to: window, for: kind)
        }
    }

    /// Reapplies the current options to every open About window.
    public func applyToOpenWindows() {
        applyToOpenWindows(for: .about)
    }

    /// Applies the current options for `kind` to a specific window. Used by the
    /// About/Acknowledgments window controllers as they build their windows.
    public func applyCurrentOptions(to window: NSWindow, for kind: AboutWindowKind) {
        apply(options(for: kind), to: window, for: kind)
    }

    /// Builds the human-readable snapshot of the current About options. Pure (no
    /// pasteboard side effect) so it is unit-testable without mutating the
    /// process clipboard; `copyConfigToPasteboard()` is the side-effecting wrapper.
    public func configSnapshot() -> String {
        let about = options(for: .about)
        return """
        # About Titlebar Debug
        about.overridesEnabled=\(about.overridesEnabled)
        about.title=\(about.windowTitle)
        about.titleVisibility=\(about.titleVisibility.rawValue)
        about.titlebarAppearsTransparent=\(about.titlebarAppearsTransparent)
        about.movableByWindowBackground=\(about.movableByWindowBackground)
        about.titled=\(about.titled)
        about.closable=\(about.closable)
        about.miniaturizable=\(about.miniaturizable)
        about.resizable=\(about.resizable)
        about.fullSizeContentView=\(about.fullSizeContentView)
        about.showToolbar=\(about.showToolbar)
        about.toolbarStyle=\(about.toolbarStyle.rawValue)
        """
    }

    /// Copies a human-readable snapshot of the current About options to the
    /// general pasteboard.
    public func copyConfigToPasteboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(configSnapshot(), forType: .string)
    }

    private func apply(_ options: AboutTitlebarDebugOptions, to window: NSWindow, for kind: AboutWindowKind) {
        let effective = options.overridesEnabled ? options : AboutTitlebarDebugOptions.defaults(for: kind)
        let resolvedTitle = effective.windowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        window.title = resolvedTitle.isEmpty ? kind.fallbackTitle : resolvedTitle
        window.titleVisibility = effective.titleVisibility.windowValue
        window.titlebarAppearsTransparent = effective.titlebarAppearsTransparent
        window.isMovableByWindowBackground = effective.movableByWindowBackground
        window.toolbarStyle = effective.toolbarStyle.windowValue

        if effective.showToolbar {
            ensureToolbar(on: window, kind: kind)
        } else if window.toolbar != nil {
            window.toolbar = nil
        }

        var styleMask = window.styleMask
        setStyleMaskBit(&styleMask, .titled, enabled: effective.titled)
        setStyleMaskBit(&styleMask, .closable, enabled: effective.closable)
        setStyleMaskBit(&styleMask, .miniaturizable, enabled: effective.miniaturizable)
        setStyleMaskBit(&styleMask, .resizable, enabled: effective.resizable)
        setStyleMaskBit(&styleMask, .fullSizeContentView, enabled: effective.fullSizeContentView)
        window.styleMask = styleMask

        let maxSize = effective.resizable ? NSSize(width: 8192, height: 8192) : kind.minimumSize
        window.minSize = kind.minimumSize
        window.maxSize = maxSize
        window.contentMinSize = kind.minimumSize
        window.contentMaxSize = maxSize
        window.invalidateShadow()
        decorator?.applyWindowDecorations(to: window)
    }

    private func ensureToolbar(on window: NSWindow, kind: AboutWindowKind) {
        guard window.toolbar == nil else { return }
        let identifier = NSToolbar.Identifier("cmux.debug.titlebar.\(kind.rawValue)")
        let toolbar = NSToolbar(identifier: identifier)
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        toolbar.displayMode = .iconOnly
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
    }

    private func setStyleMaskBit(
        _ styleMask: inout NSWindow.StyleMask,
        _ bit: NSWindow.StyleMask,
        enabled: Bool
    ) {
        if enabled {
            styleMask.insert(bit)
        } else {
            styleMask.remove(bit)
        }
    }
}

#endif
