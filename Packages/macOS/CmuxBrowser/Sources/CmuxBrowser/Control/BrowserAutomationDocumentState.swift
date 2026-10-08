public import Foundation

/// Browser automation state that belongs to each surface's current top-level document.
///
/// `browser frame select` stores a CSS selector for the frame later commands
/// run in, and the element refs handed out by `browser snapshot` and the
/// `find` commands (`@e1`, `@e2`, ...) each stand for a CSS selector. A
/// selector only means something in the document it was resolved in, so the
/// owner reports every main-frame commit through
/// ``mainFrameDidCommit(surfaceID:)``.
///
/// The type is a value: the app's browser controller owns one instance and
/// serializes access to it.
///
/// ```swift
/// var state = BrowserAutomationDocumentState()
/// state.selectFrame("#checkout", surfaceID: surfaceID)
/// let ref = state.allocateElementRef(selector: "#pay", surfaceID: surfaceID)
/// state.selector(forElementRef: ref, surfaceID: surfaceID)  // "#pay"
/// ```
public struct BrowserAutomationDocumentState: Sendable {
    private struct ElementRef: Sendable {
        let surfaceID: UUID
        let selector: String
    }

    private var nextElementOrdinal = 1
    private var elementRefs: [String: ElementRef] = [:]
    private var frameSelectors: [UUID: String] = [:]

    /// Creates a state with no selected frames and no element refs.
    public init() {}

    /// Returns the selector of the frame selected on a surface, or `nil` for the main frame.
    /// - Parameter surfaceID: The browser surface to look up.
    /// - Returns: The selector stored by ``selectFrame(_:surfaceID:)``, if any.
    public func frameSelector(surfaceID: UUID) -> String? {
        frameSelectors[surfaceID]
    }

    /// Makes later commands on a surface run in the frame matching `selector`.
    /// - Parameters:
    ///   - selector: CSS selector of a same-origin frame in the current document.
    ///   - surfaceID: The browser surface the selection applies to.
    public mutating func selectFrame(_ selector: String, surfaceID: UUID) {
        frameSelectors[surfaceID] = selector
    }

    /// Makes later commands on a surface run in the main frame again.
    /// - Parameter surfaceID: The browser surface to reset.
    public mutating func selectMainFrame(surfaceID: UUID) {
        frameSelectors.removeValue(forKey: surfaceID)
    }

    /// Hands out a new element ref for a selector on a surface.
    ///
    /// Ordinals count up across all surfaces and are never reused, so a ref
    /// that was dropped cannot later resolve to a different element.
    /// - Parameters:
    ///   - selector: CSS selector the ref stands for.
    ///   - surfaceID: The browser surface the element was found on.
    /// - Returns: The ref, in the form `@e<ordinal>`.
    public mutating func allocateElementRef(selector: String, surfaceID: UUID) -> String {
        let ref = "@e\(nextElementOrdinal)"
        nextElementOrdinal += 1
        elementRefs[ref] = ElementRef(surfaceID: surfaceID, selector: selector)
        return ref
    }

    /// Returns the selector an element ref stands for on a surface.
    /// - Parameters:
    ///   - ref: A ref returned by ``allocateElementRef(selector:surfaceID:)``.
    ///   - surfaceID: The browser surface the command targets.
    /// - Returns: The selector, or `nil` when the ref is unknown or belongs to another surface.
    public func selector(forElementRef ref: String, surfaceID: UUID) -> String? {
        guard let entry = elementRefs[ref], entry.surfaceID == surfaceID else { return nil }
        return entry.selector
    }

    /// Records that a surface's main frame committed a new document.
    /// - Parameter surfaceID: The browser surface whose top-level document was replaced.
    public mutating func mainFrameDidCommit(surfaceID: UUID) {
    }

    /// Forgets the selected frame and every element ref of a closed surface.
    /// - Parameter surfaceID: The browser surface that went away.
    public mutating func removeSurface(_ surfaceID: UUID) {
        frameSelectors.removeValue(forKey: surfaceID)
        elementRefs = elementRefs.filter { $0.value.surfaceID != surfaceID }
    }
}
