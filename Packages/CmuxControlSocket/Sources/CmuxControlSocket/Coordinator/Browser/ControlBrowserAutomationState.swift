public import Foundation

/// The browser DOM-automation selection state that used to live as private
/// dictionaries on `TerminalController` (`v2BrowserElementRefs`,
/// `v2BrowserNextElementOrdinal`, `v2BrowserFrameSelectorBySurface`,
/// `v2BrowserInitScriptsBySurface`, `v2BrowserInitStylesBySurface`,
/// `v2BrowserDialogQueueBySurface`), moved behind one owner so the coordinator
/// and the remaining app-side browser bodies (snapshot ref minting,
/// `state.save`/`state.load` frame selectors, surface cleanup) share a single
/// source of truth.
///
/// `@MainActor` because every reader/writer (the coordinator, the app's
/// browser command bodies, surface cleanup) runs on the main actor, exactly as
/// the legacy controller state did. Exposed to the app through the
/// ``ControlBrowserAutomationContext/controlBrowserAutomationState``
/// requirement; the conforming controller owns the single instance.
@MainActor
public final class ControlBrowserAutomationState {
    private var nextElementOrdinal = 1
    private var elementRefs: [String: ControlBrowserElementRefEntry] = [:]
    private var frameSelectorBySurface: [UUID: String] = [:]
    private var initScriptsBySurface: [UUID: [String]] = [:]
    private var initStylesBySurface: [UUID: [String]] = [:]
    private var dialogQueueBySurface: [UUID: [ControlBrowserPendingDialog]] = [:]

    /// Creates empty automation state.
    public init() {}

    // MARK: - Element refs

    /// Mints the next `@eN` element ref for a selector resolved on a surface
    /// (was `v2BrowserAllocateElementRef`; the ordinal is global, not
    /// per-surface, exactly as before).
    ///
    /// - Parameters:
    ///   - surfaceID: The browser surface the selector was resolved on.
    ///   - selector: The CSS selector to pin.
    /// - Returns: The minted `@eN` ref token.
    public func allocateElementRef(surfaceID: UUID, selector: String) -> String {
        let ref = "@e\(nextElementOrdinal)"
        nextElementOrdinal += 1
        elementRefs[ref] = ControlBrowserElementRefEntry(surfaceID: surfaceID, selector: selector)
        return ref
    }

    /// Expands a raw selector param into a CSS selector (was
    /// `v2BrowserResolveSelector`): `@eN` (or bare `eN`) refs resolve through
    /// the element-ref table and must belong to the same surface; anything
    /// else passes through trimmed. Returns `nil` for empty input or an
    /// unknown/foreign ref.
    ///
    /// - Parameters:
    ///   - rawSelector: The raw `selector`/`ref` param value.
    ///   - surfaceID: The surface the command targets.
    /// - Returns: The CSS selector, or `nil`.
    public func resolveSelector(_ rawSelector: String, surfaceID: UUID) -> String? {
        let trimmed = rawSelector.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let refKey: String? = {
            if trimmed.hasPrefix("@e") { return trimmed }
            if trimmed.hasPrefix("e"), Int(trimmed.dropFirst()) != nil { return "@\(trimmed)" }
            return nil
        }()

        if let refKey {
            guard let entry = elementRefs[refKey], entry.surfaceID == surfaceID else { return nil }
            return entry.selector
        }
        return trimmed
    }

    // MARK: - Frame selectors

    /// The CSS selector of the iframe currently selected on a surface via
    /// `browser.frame.select`, if any (was `v2BrowserCurrentFrameSelector`).
    ///
    /// - Parameter surfaceID: The browser surface.
    /// - Returns: The frame selector, or `nil` for the main frame.
    public func frameSelector(forSurface surfaceID: UUID) -> String? {
        frameSelectorBySurface[surfaceID]
    }

    /// Sets or clears the selected-frame selector for a surface
    /// (`browser.frame.select` / `browser.frame.main`, and `state.load`).
    ///
    /// - Parameters:
    ///   - selector: The frame selector, or `nil` to return to the main frame.
    ///   - surfaceID: The browser surface.
    public func setFrameSelector(_ selector: String?, forSurface surfaceID: UUID) {
        if let selector {
            frameSelectorBySurface[surfaceID] = selector
        } else {
            frameSelectorBySurface.removeValue(forKey: surfaceID)
        }
    }

    // MARK: - Init scripts and styles

    /// Records a `browser.addinitscript` script for a surface.
    ///
    /// - Parameters:
    ///   - script: The script source.
    ///   - surfaceID: The browser surface.
    /// - Returns: The new script count (the legacy `scripts` wire field).
    public func appendInitScript(_ script: String, forSurface surfaceID: UUID) -> Int {
        var scripts = initScriptsBySurface[surfaceID] ?? []
        scripts.append(script)
        initScriptsBySurface[surfaceID] = scripts
        return scripts.count
    }

    /// Records a `browser.addstyle` stylesheet for a surface.
    ///
    /// - Parameters:
    ///   - css: The CSS source.
    ///   - surfaceID: The browser surface.
    /// - Returns: The new style count (the legacy `styles` wire field).
    public func appendInitStyle(_ css: String, forSurface surfaceID: UUID) -> Int {
        var styles = initStylesBySurface[surfaceID] ?? []
        styles.append(css)
        initStylesBySurface[surfaceID] = styles
        return styles.count
    }

    /// The recorded init scripts for a surface, in insertion order.
    ///
    /// - Parameter surfaceID: The browser surface.
    /// - Returns: The scripts, oldest first.
    public func initScripts(forSurface surfaceID: UUID) -> [String] {
        initScriptsBySurface[surfaceID] ?? []
    }

    /// The recorded init styles for a surface, in insertion order.
    ///
    /// - Parameter surfaceID: The browser surface.
    /// - Returns: The styles, oldest first.
    public func initStyles(forSurface surfaceID: UUID) -> [String] {
        initStylesBySurface[surfaceID] ?? []
    }

    // MARK: - Pending dialogs

    /// Appends a pending dialog to its surface's FIFO queue, keeping the
    /// legacy 16-entry bound (oldest entries drop first).
    ///
    /// - Parameter dialog: The dialog to enqueue.
    /// - Returns: The `dialogID`s of entries dropped by the bound, so the app
    ///   can release their stored completion handlers (the legacy behavior
    ///   dropped the closures unrun; releasing unrun is identical).
    public func enqueueDialog(_ dialog: ControlBrowserPendingDialog) -> [UUID] {
        var queue = dialogQueueBySurface[dialog.surfaceID] ?? []
        queue.append(dialog)
        var dropped: [UUID] = []
        if queue.count > 16 {
            // Keep bounded memory while preserving FIFO semantics for newest entries.
            dropped = queue.prefix(queue.count - 16).map(\.dialogID)
            queue.removeFirst(queue.count - 16)
        }
        dialogQueueBySurface[dialog.surfaceID] = queue
        return dropped
    }

    /// The pending dialogs for a surface, oldest first (was the queue behind
    /// `v2BrowserPendingDialogs`).
    ///
    /// - Parameter surfaceID: The browser surface.
    /// - Returns: The pending dialogs.
    public func pendingDialogs(forSurface surfaceID: UUID) -> [ControlBrowserPendingDialog] {
        dialogQueueBySurface[surfaceID] ?? []
    }

    /// Removes and returns the oldest pending dialog for a surface (was
    /// `v2BrowserPopDialog`). The caller resolves its completion handler via
    /// the seam's `controlBrowserResolvePendingDialog(dialogID:accept:text:)`.
    ///
    /// - Parameter surfaceID: The browser surface.
    /// - Returns: The popped dialog, or `nil` when the queue is empty.
    public func popDialog(forSurface surfaceID: UUID) -> ControlBrowserPendingDialog? {
        var queue = dialogQueueBySurface[surfaceID] ?? []
        guard !queue.isEmpty else { return nil }
        let first = queue.removeFirst()
        dialogQueueBySurface[surfaceID] = queue
        return first
    }

    // MARK: - Cleanup

    /// Drops every per-surface entry for a closed surface (the browser slice
    /// of the legacy `cleanupSurfaceState(surfaceIds:)`).
    ///
    /// - Parameter surfaceID: The closed surface.
    /// - Returns: The `dialogID`s of dropped pending dialogs, so the app can
    ///   release their stored completion handlers.
    @discardableResult
    public func purgeSurfaceState(surfaceID: UUID) -> [UUID] {
        frameSelectorBySurface.removeValue(forKey: surfaceID)
        initScriptsBySurface.removeValue(forKey: surfaceID)
        initStylesBySurface.removeValue(forKey: surfaceID)
        let droppedDialogs = (dialogQueueBySurface.removeValue(forKey: surfaceID) ?? []).map(\.dialogID)
        elementRefs = elementRefs.filter { $0.value.surfaceID != surfaceID }
        return droppedDialogs
    }
}
