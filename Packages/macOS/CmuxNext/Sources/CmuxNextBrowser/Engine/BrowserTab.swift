public import AppKit
public import Foundation
public import Observation

/// One live page. Engine-neutral: the chrome, the App layer, and automation
/// talk only to this protocol.
///
/// Conforming types are `@Observable`, so `state`, `favicon`, and
/// `pendingPrompts` can be tracked with Observation.
@MainActor
public protocol BrowserTab: AnyObject, Observable, Sendable {
    var id: BrowserTabID { get }
    var engineKind: BrowserEngineKind { get }
    var profileID: BrowserProfileID { get }
    var presentation: BrowserPresentation { get }

    /// The view to place in the pane. For `.childWindow` engines this is the
    /// placeholder the child window tracks.
    var contentView: NSView { get }

    var state: BrowserTabState { get }
    var favicon: NSImage? { get }
    /// Unanswered permission requests and JavaScript dialogs, oldest first.
    var pendingPrompts: [BrowserPrompt] { get }

    var delegate: (any BrowserTabDelegate)? { get set }
    var keyRouter: (any BrowserKeyRouting)? { get set }

    func load(_ url: URL)
    func goBack()
    func goForward()
    func reload()
    func stop()

    /// Gives or removes keyboard focus from the page.
    func setFocused(_ focused: Bool)
    /// Shows or hides and pauses the page, synchronously, before returning.
    /// The App's content lifecycle is the only caller (one event per
    /// transition, in order); `.childWindow` engines hide their page window
    /// at once, which Chromium sees as the page becoming hidden.
    func setContentVisible(_ visible: Bool)

    /// Page pixels for hover previews and occlusion placeholders.
    func snapshot() async throws -> CGImage

    /// Evaluates a script and returns its completion value.
    func evaluate(_ script: String, world: BrowserScriptWorld) async throws -> BrowserJSValue

    /// Highlights the next or previous match of `text`.
    func find(_ text: String, direction: BrowserFindDirection, caseSensitive: Bool) async -> BrowserFindResult
    func clearFind()

    func setZoom(_ zoom: Double)

    /// Leaves in-pane content fullscreen, if active.
    func exitContentFullscreen()

    func showDevTools()

    /// An agent is driving this tab (browser automation): saved passwords
    /// stop filling in it for the rest of its life, so a page script cannot
    /// read one after an automated click. Agents sign in only through the
    /// secure sign-in sheet (plans/cmux-next/browser.md, "Secure sign-in").
    func markAgentDriven()

    /// Whether `markAgentDriven` has run on this page.
    var isAgentDriven: Bool { get }

    /// Tears the page down. Pending prompts are dismissed. Idempotent.
    func close()
}

extension BrowserTab {
    /// Engines without Chromium password autofill have nothing to withhold.
    public func markAgentDriven() {}
    public var isAgentDriven: Bool { false }

    public func zoomIn() { setZoom(BrowserZoom.zoomIn(from: state.zoom)) }
    public func zoomOut() { setZoom(BrowserZoom.zoomOut(from: state.zoom)) }
    public func resetZoom() { setZoom(1) }

    public func evaluate(_ script: String) async throws -> BrowserJSValue {
        try await evaluate(script, world: .page)
    }
}
