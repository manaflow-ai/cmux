public import Foundation

/// The page side of design mode: classic's `BrowserDesignModeRuntime.js`, copied as is, and the
/// calls cmux-next makes into it. It runs only in cmux's isolated world, so a page can neither call
/// it nor post as it.
public nonisolated struct BrowserDesignModeScript: Sendable {
    /// The handler name the runtime posts to (`webkit.messageHandlers.cmuxDesignMode`).
    public static let channel = "cmuxDesignMode"
    /// The DevTools binding Chromium's isolated world posts through (``chromiumPrelude``).
    public static let chromiumBinding = "cmuxDesignModePost"

    private let resourceURL: URL?

    public init() {
        self.init(resourceURL: Bundle.module.url(forResource: "BrowserDesignModeRuntime", withExtension: "js"))
    }

    init(resourceURL: URL?) { self.resourceURL = resourceURL }

    /// The runtime's source.
    /// - Throws: A Cocoa file error when the bundled resource is missing or unreadable.
    public func runtime() throws -> String {
        guard let resourceURL else { throw CocoaError(.fileNoSuchFile) }
        return try String(contentsOf: resourceURL, encoding: .utf8)
    }

    /// The script that installs the runtime if needed and turns design mode on; it returns the
    /// runtime's first snapshot. In Chromium it first gives the world the WebKit-shaped handler the
    /// runtime posts to, backed by the ``chromiumBinding`` binding.
    public func enableScript(chromium: Bool) throws -> String {
        (chromium ? Self.chromiumPrelude : "") + "\n" + (try runtime()) + "\n;globalThis.__cmuxDesignMode.enable();"
    }

    /// Turns design mode off and restores every edit; harmless when it is not on.
    public static let disableScript = "globalThis.__cmuxDesignMode?.destroy(); true"

    /// Chromium's isolated world has no `webkit.messageHandlers`: route the runtime's
    /// `postMessage` to the DevTools binding as JSON.
    static let chromiumPrelude = """
    (() => {
      if (globalThis.webkit?.messageHandlers?.\(channel)) return;
      const post = (message) => { try { globalThis.\(chromiumBinding)(JSON.stringify(message)); } catch (_) {} };
      globalThis.webkit = { messageHandlers: { \(channel): { postMessage: post } } };
    })();
    """
}
