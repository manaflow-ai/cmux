import AppKit
import CmuxBrowser
import Foundation

/// The pane-facing engine seam. BrowserPanel and automation talk to this
/// adapter instead of reaching into a concrete renderer for shared actions.
@MainActor
protocol BrowserPaneEngineAdapter: AnyObject {
    var kind: BrowserEngineKind { get }
    var contentView: NSView? { get }
    var remoteDebuggingEndpoint: BrowserCDPEndpoint? { get }
    var startupReadinessTask: Task<Void, Never>? { get }

    func start(initialURL: URL?)
    func stop()
    func navigate(to url: URL) async throws
    func goBack() async throws
    func goForward() async throws
    func reload() async throws
    func hardReload() async throws
    func evaluateJavaScript(_ script: String, awaitPromise: Bool) async throws -> CDPValue
    func screenshotPNG() async throws -> Data
}
