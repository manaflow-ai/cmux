public import CoreGraphics

extension BrowserSectionSelection {
    /// Takes `tab`'s page snapshot (the one Screenshot Page copies) and crops
    /// it to the selection.
    /// - Parameter tab: The page the selection was dragged over.
    /// - Returns: The selected part of the page.
    /// - Throws: The snapshot's error, or ``BrowserTabError/snapshotUnavailable``
    ///   without a selection.
    @MainActor
    public func capture(from tab: any BrowserTab) async throws -> CGImage {
        let page = try await tab.snapshot()
        guard let section = crop(page) else { throw BrowserTabError.snapshotUnavailable }
        return section
    }
}
