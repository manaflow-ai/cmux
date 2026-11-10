import AppKit

/// AppKit's panel prompt, read as an optional (``OpenPanelLabels``).
extension NSSavePanel: OpenPanelLabels {
    var openPanelPrompt: String? { prompt }
}
