public import AppKit

/// The application object that holds the app's one ``WindowMoments`` (cmux's `CmuxApplication`).
///
/// A view finds its window's key tracker and indicator set from its window alone
/// (``WindowKeyFamily/live(_:)``); the moments they listen through are the ones the running
/// application holds. A process whose application holds none (a package test that hosts bare
/// views) gives its windows no tracker: their views follow no key or indicator moment, and a test
/// that needs them passes its own ``WindowMoments``.
@MainActor
public protocol WindowMomentsHosting: NSApplication {
    /// The app's one listener for its windows' moments, made with the application object, before
    /// any window.
    var windowMoments: WindowMoments { get }
}
