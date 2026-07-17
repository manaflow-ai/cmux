import SwiftUI

/// Per-page mounting context handed to the pager's content builder.
struct SurfacePageContext {
    /// Whether this page is the settled, viewed page (grants viewport, may
    /// hold the keyboard, hosts the composer). Only flips when a swipe
    /// SETTLES, never mid-drag, so a fast multi-page fling cannot churn
    /// viewport grants across every crossed pane.
    let isCurrent: Bool
    /// Whether this page should mount real content. The current page and the
    /// drag anchor's immediate neighbors mount live so a swipe peeks REAL
    /// streaming terminals; pages further out render a cheap placeholder.
    let isMounted: Bool
}

/// Horizontal full-bleed pager over a workspace's surfaces in spatial order.
///
/// Native paging physics via a paging `ScrollView`; neighbors of the current
/// page stay mounted (live peek), everything further renders as placeholder.
/// Selection is two-way: a swipe that settles on a new page fires
/// `onPageSettled`; external selection (chip tap, deep link) scrolls the pager.
struct SurfacePagerView<Page: View>: View {
    let pageIDs: [String]
    let currentID: String?
    let onPageSettled: (String) -> Void
    @ViewBuilder let page: (String, SurfacePageContext) -> Page

    /// The page id the scroll view reports at the viewport anchor. Live
    /// during a drag (drives the mount window); committed to the owner only
    /// when scrolling settles.
    @State private var scrolledID: String?
    /// Whether the scroll view is currently moving (dragging, decelerating,
    /// or animating a programmatic scroll).
    @State private var isScrolling = false

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(pageIDs, id: \.self) { id in
                        page(id, context(for: id))
                            .frame(width: geometry.size.width, height: geometry.size.height)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollIndicators(.hidden)
            .scrollPosition(id: $scrolledID, anchor: .leading)
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .onScrollPhaseChange { _, newPhase in
                isScrolling = newPhase != .idle
                guard newPhase == .idle else { return }
                commitSettledPageIfNeeded()
            }
            .onAppear {
                scrolledID = currentID ?? pageIDs.first
            }
            .onChange(of: currentID) { _, newValue in
                guard let newValue, newValue != scrolledID else { return }
                withAnimation(.snappy(duration: 0.3)) {
                    scrolledID = newValue
                }
            }
            .onChange(of: scrolledID) { _, _ in
                // A binding write can land after the phase already returned
                // to idle (fast flick): commit here too. Mid-drag writes are
                // filtered by the phase guard.
                guard !isScrolling else { return }
                commitSettledPageIfNeeded()
            }
            .onChange(of: pageIDs) { _, newIDs in
                // The scrolled page disappeared (tab closed): snap to the
                // reconciled current selection.
                if let scrolledID, !newIDs.contains(scrolledID) {
                    self.scrolledID = currentID ?? newIDs.first
                }
            }
        }
        .accessibilityIdentifier("MobileSurfacePager")
    }

    private func commitSettledPageIfNeeded() {
        guard let scrolledID, scrolledID != currentID, pageIDs.contains(scrolledID) else { return }
        onPageSettled(scrolledID)
    }

    private func context(for id: String) -> SurfacePageContext {
        let isCurrent = id == currentID
        let anchor = scrolledID ?? currentID
        guard let index = pageIDs.firstIndex(of: id) else {
            return SurfacePageContext(isCurrent: isCurrent, isMounted: isCurrent)
        }
        var mounted = isCurrent
        if let anchorIndex = pageIDs.firstIndex(of: anchor ?? "") {
            mounted = mounted || abs(index - anchorIndex) <= 1
        }
        if let currentIndex = pageIDs.firstIndex(of: currentID ?? "") {
            mounted = mounted || abs(index - currentIndex) <= 1
        }
        return SurfacePageContext(isCurrent: isCurrent, isMounted: mounted)
    }
}
