public import Foundation

extension [MainWindowSummary] {
    /// Returns these summaries ordered for the window/workspace move-target
    /// menus, putting the reference window first, then key windows, then visible
    /// windows, then a stable tiebreak on the window identifier's string form.
    ///
    /// A pure, total ordering over the value-typed summaries: the app target
    /// reads the live `NSWindow`/`TabManager` state into `[MainWindowSummary]`
    /// and hands it here, keeping the comparator (which touches no app-target
    /// state) in the window-management domain. The comparator is the faithful
    /// lift of the god file's `orderedMainWindowSummaries(referenceWindowId:)`
    /// sort: reference-window precedence, then `isKeyWindow`, then `isVisible`,
    /// then `windowId.uuidString` ascending.
    public func orderedByReference(referenceWindowId: UUID?) -> [MainWindowSummary] {
        sorted { lhs, rhs in
            let lhsIsReference = lhs.windowId == referenceWindowId
            let rhsIsReference = rhs.windowId == referenceWindowId
            if lhsIsReference != rhsIsReference { return lhsIsReference }
            if lhs.isKeyWindow != rhs.isKeyWindow { return lhs.isKeyWindow }
            if lhs.isVisible != rhs.isVisible { return lhs.isVisible }
            return lhs.windowId.uuidString < rhs.windowId.uuidString
        }
    }
}
