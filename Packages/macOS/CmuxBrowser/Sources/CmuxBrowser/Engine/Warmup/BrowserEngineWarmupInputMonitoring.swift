import Foundation

/// Reports user input and menu tracking to ``BrowserEngineWarmup`` while it
/// waits for an idle moment.
///
/// The warmup installs the monitor only while it waits, so an app that never
/// expects a Chromium page pays nothing per event.
@MainActor
public protocol BrowserEngineWarmupInputMonitoring: AnyObject {
    /// `true` while a menu is tracking the mouse.
    var isTrackingMenu: Bool { get }
    /// Starts reporting key and mouse input and the end of menu tracking.
    /// - Parameters:
    ///   - onInput: Called for each key or mouse event the app receives.
    ///   - onMenuTrackingEnd: Called when a menu stops tracking.
    func start(onInput: @escaping @MainActor () -> Void, onMenuTrackingEnd: @escaping @MainActor () -> Void)
    /// Stops reporting. Idempotent.
    func stop()
}
