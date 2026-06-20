public import Foundation

/// The outcome of `browser.addinitscript`, the typed twin of the legacy
/// `TerminalController.v2BrowserAddInitScript(params:)` body.
///
/// The `Missing script` param error is emitted by the coordinator before the
/// witness runs. The witness reproduces the `v2BrowserWithPanel` head, appends
/// the script to the per-surface init-script cache, registers a
/// document-start `WKUserScript`, and evaluates the script once immediately
/// (the legacy body ignores that eval's result). The coordinator shapes the
/// identity payload plus `scripts` (the post-append count).
public enum ControlBrowserAddInitScriptResolution: Sendable, Equatable {
    /// Panel resolution failed.
    case failed(ControlBrowserPanelResolutionFailure)
    /// Resolved: the owning workspace, the resolved surface, and the post-append
    /// init-script count.
    case resolved(workspaceID: UUID, surfaceID: UUID, scriptCount: Int)
}

/// The outcome of `browser.addscript`, the typed twin of the legacy
/// `TerminalController.v2BrowserAddScript(params:)` body.
///
/// The `Missing script` param error is emitted by the coordinator before the
/// witness runs. The witness reproduces the `v2BrowserWithPanel` head and
/// evaluates the script once, returning either the JS error message or the
/// normalized result value. The coordinator shapes the identity payload plus
/// `value`.
public enum ControlBrowserAddScriptResolution: Sendable, Equatable {
    /// Panel resolution failed.
    case failed(ControlBrowserPanelResolutionFailure)
    /// The injected JavaScript failed (`js_error` / the JS error message).
    case jsError(message: String)
    /// Resolved: the owning workspace, the resolved surface, and the normalized
    /// eval result value.
    case resolved(workspaceID: UUID, surfaceID: UUID, value: JSONValue)
}

/// The outcome of `browser.addstyle`, the typed twin of the legacy
/// `TerminalController.v2BrowserAddStyle(params:)` body.
///
/// The `Missing css/style content` param error is emitted by the coordinator
/// before the witness runs. The witness reproduces the `v2BrowserWithPanel`
/// head, appends the CSS to the per-surface init-style cache, registers a
/// document-start `WKUserScript` that injects a `<style>` element, and
/// evaluates it once immediately (the legacy body ignores that eval's result).
/// The coordinator shapes the identity payload plus `styles` (the post-append
/// count).
public enum ControlBrowserAddStyleResolution: Sendable, Equatable {
    /// Panel resolution failed.
    case failed(ControlBrowserPanelResolutionFailure)
    /// Resolved: the owning workspace, the resolved surface, and the post-append
    /// init-style count.
    case resolved(workspaceID: UUID, surfaceID: UUID, styleCount: Int)
}
