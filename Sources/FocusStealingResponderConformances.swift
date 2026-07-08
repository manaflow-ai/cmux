import CmuxFoundation
import WebKit

// Marker conformances for the terminal-surface and browser view types so the command
// palette focus-stealing classification (in CmuxCommandPaletteUI) can test
// `any FocusStealingResponder` instead of importing these concrete app-target view
// types upward across the package graph.
//
// These conformances must live in the executable app target: a lower package cannot
// extend a type owned by a higher one, and `GhosttyNSView` / `GhosttySurfaceScrollView`
// are app-target views. `WKWebView` is a system type, so its conformance is also
// declared here next to the others that share the marker's meaning.

extension GhosttyNSView: FocusStealingResponder {}

extension GhosttySurfaceScrollView: FocusStealingResponder {}

extension WKWebView: @retroactive FocusStealingResponder {}
