import AppKit

/// The tinted tab icon images a tab strip draws, cached per icon, tint, size and scale: agent
/// brand marks, cmux icon pack icons and SF Symbols.
///
/// The composition root constructs one (`AppServices.tabIconCaches`) and passes it down by
/// `init` to every strip (each pane's strip and each workspace's screen bar); ``TabStripView``
/// hands it to every tab cell, group chip and its hover card body once, at construction, so a
/// sync does no extra work. Strips on one instance draw each icon once per process; a test or the
/// demo builds its own instance.
///
/// The user icon images (drawn emoji, known symbol names) are not part of it: `TabUserIcon`
/// reads them from the process-wide `TabUserIconImages`.
///
/// ```swift
/// let caches = TabIconCaches()
/// let top = TabStripView(model: topModel, iconCaches: caches)
/// let bottom = TabStripView(model: bottomModel, iconCaches: caches)
/// ```
public final class TabIconCaches {
    /// Agent brand marks in the tab's tint.
    let agentMarks = TabAgentMarkCache()
    /// cmux icon pack icons in the tab's tint.
    let packIcons = TabPackIconCache()
    /// Tinted SF Symbols.
    let symbols = TabSymbolCache()

    /// Makes empty caches; images are drawn on first use.
    public init() {}

    /// Images held across the three caches.
    var entryCount: Int { agentMarks.count + packIcons.count + symbols.count }
}
