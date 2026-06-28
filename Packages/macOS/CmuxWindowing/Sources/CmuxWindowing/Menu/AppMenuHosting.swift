/// App-target seam for the application/dock menu-building and menu-validation
/// decisions ``AppMenuCoordinator`` owns, mirroring ``WindowLifecycleHosting``:
/// the app delegate conforms and injects itself, and the coordinator weak-refs
/// back so ownership is one-directional (the delegate owns the coordinator
/// strongly).
///
/// The decisions ``AppMenuCoordinator`` makes today — the dock menu spec, the
/// Reload-Configuration item locate/key-equivalent, the new-workspace
/// context-menu plan, `NSMenuItemValidation` validity, and the main-menu
/// shortcut-disable paths — all take their app-side leaf reads as value
/// projections passed into each method, so this seam currently exposes no leaf
/// reads of its own. It anchors the delegate ↔ coordinator relationship the same
/// way ``WindowLifecycleHosting`` anchors the window-lifecycle layer, so future
/// menu decisions that need live host state can read through it.
@MainActor
public protocol AppMenuHosting: AnyObject {}
