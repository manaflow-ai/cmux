/// Marker conformance for AppKit responder/view types that must not be allowed to
/// reclaim first-responder focus while a focus-owning overlay (the command palette)
/// is visible.
///
/// Terminal surfaces (`GhosttyNSView`, `GhosttySurfaceScrollView`) and embedded web
/// views (`WKWebView`) conform to this marker in the executable app target. Focus
/// classification code (in `CmuxCommandPaletteUI`) walks the responder/view hierarchy
/// testing `any FocusStealingResponder`, so it never has to import the concrete
/// terminal or browser view types upward across the package graph.
///
/// The protocol is a pure marker: it has no requirements and carries no AppKit
/// dependency, so it can live in the foundation leaf that every domain depends on.
public protocol FocusStealingResponder {}
