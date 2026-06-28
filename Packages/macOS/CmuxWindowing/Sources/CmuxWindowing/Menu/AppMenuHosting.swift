/// App-target seam for the application/dock menu-building decisions
/// ``AppMenuCoordinator`` owns, mirroring ``WindowLifecycleHosting``: the app
/// delegate conforms and injects itself, and the coordinator weak-refs back so
/// ownership is one-directional (the delegate owns the coordinator strongly).
///
/// The dock-menu decision is currently stateless, so this seam exposes no leaf
/// reads yet. It anchors the delegate ↔ coordinator relationship that future
/// menu-validation decisions (item enable/disable state, contextual items) will
/// read through, the same way ``WindowLifecycleHosting`` anchors the
/// window-lifecycle layer.
@MainActor
public protocol AppMenuHosting: AnyObject {}
