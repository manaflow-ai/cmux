import Foundation

/// An engine that can be started ahead of its first page.
///
/// Chromium has two unavoidable main-thread steps, starting the runtime and
/// creating its first window (about 80-160 ms each). ``BrowserEngineWarmup``
/// moves the first one out of the user's way by calling ``warmStart(reason:)``
/// at an idle moment once a Chromium page is likely. WebKit needs no warmup.
///
/// Conformers must keep ``availability`` cheap: it may only check that the
/// runtime is bundled, never load it, so an app that never opens a Chromium
/// page never maps the framework or spawns a helper process.
@MainActor
public protocol BrowserEngineWarming: AnyObject {
    /// Whether the engine can start in this process.
    var availability: BrowserEngineAvailability { get }
    /// `true` once the engine has started and can create pages without
    /// further startup work.
    var isRunning: Bool { get }
    /// Maps the engine's framework off the main thread without running any
    /// engine code. Idempotent; does nothing when the engine is unavailable.
    func preload()
    /// Starts the engine. Idempotent; returns when startup finished or failed.
    /// - Parameter reason: Why a page of this engine is likely now, for logs.
    func warmStart(reason: BrowserEngineWarmupReason) async
}
