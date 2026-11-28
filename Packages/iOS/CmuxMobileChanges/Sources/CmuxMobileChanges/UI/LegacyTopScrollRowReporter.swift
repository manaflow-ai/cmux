import SwiftUI

/// Observes row crossings on iOS 17 without binding SwiftUI state to the scroll offset.
struct LegacyTopScrollRowReporter: ViewModifier {
    let rowID: String
    let isFirstRow: Bool
    let tracker: ScrollRowTracker
    let onRowChanged: @MainActor @Sendable (String?) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18.0, macOS 15.0, *) {
            content
        } else {
            content.onGeometryChange(for: Bool.self) { geometry in
                let frame = geometry.frame(in: .named(ObjectIdentifier(tracker)))
                // Include the first row during top inset and pull-to-refresh displacement.
                return frame.maxY > 0 && (frame.minY <= 0 || isFirstRow)
            } action: { isTopRow in
                guard isTopRow, tracker.topRowID != rowID else { return }
                tracker.topRowID = rowID
                // The pager store is render-inert. Keeping it current also covers
                // a page swipe or refresh before the scroll view comes to rest.
                onRowChanged(rowID)
            }
        }
    }
}
