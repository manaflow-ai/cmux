/// Toggles react-grab on a page: hover an element, click, and its React component source is copied.
///
/// One shared path for Toggle React Grab on every entrypoint (palette, View menu, keyboard, and
/// `cmux browser toggle-react-grab` through `action run`). It works on both engines through
/// ``BrowserTab/evaluate(_:world:gesture:)`` in the page world, where react-grab must run to read React's
/// internals. The first toggle on a document loads the library from ``ReactGrabScriptSource`` and
/// turns it on; later toggles flip the loaded library. A new document starts without it.
///
/// ```swift
/// let grab = ReactGrab(scripts: ReactGrabScriptLoader())
/// try await grab.toggle(tab)
/// ```
public nonisolated struct ReactGrab: Sendable {
    private let scripts: any ReactGrabScriptSource

    /// Creates the toggle.
    ///
    /// - Parameter scripts: Where the library comes from; production passes ``ReactGrabScriptLoader``.
    public init(scripts: any ReactGrabScriptSource) {
        self.scripts = scripts
    }

    /// Flips react-grab on `tab`, loading it first when the page does not have it.
    ///
    /// - Parameter tab: The page to act on.
    /// - Returns: Whether the library was loaded or an existing one toggled.
    /// - Throws: The script source's error, or ``BrowserTabError`` from the page.
    @MainActor
    @discardableResult
    public func toggle(_ tab: any BrowserTab) async throws -> ReactGrabOutcome {
        if try await tab.evaluate(Self.toggleScript, world: .page, gesture: .agent) == .bool(true) { return .toggled }
        let library = try await scripts.script()
        _ = try await tab.evaluate(library + "\n;\n" + Self.activateScript, world: .page, gesture: .agent)
        return .loaded
    }

    /// Toggles a loaded react-grab; answers whether one was there.
    static let toggleScript = """
    (function () {
        var api = window.__REACT_GRAB__;
        if (api && typeof api.toggle === 'function') { api.toggle(); return true; }
        return false;
    })();
    """

    /// Turns react-grab on right after the library runs, or when it announces itself later.
    static let activateScript = """
    (function () {
        var api = window.__REACT_GRAB__;
        if (api && typeof api.activate === 'function') { api.activate(); return true; }
        window.addEventListener('react-grab:init', function (event) {
            var ready = event.detail;
            if (ready && typeof ready.activate === 'function') { ready.activate(); }
        }, { once: true });
        return false;
    })();
    """
}
