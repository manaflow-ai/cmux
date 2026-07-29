#if os(iOS)
import SwiftUI

/// Horizontal pager for the onboarding tour. Swipes and the chrome buttons
/// drive the same committed `stage`, so scene analytics and connection
/// side effects fire identically for both. The track ends at the connect
/// stage; completing onboarding (sign-in, permissions, pairing) stays on the
/// footer buttons, so a swipe can never skip a gated step.
struct OnboardingPageViewport<PageContent: View>: View {
    let stage: OnboardingStage
    let onNavigate: (OnboardingStage) -> Void
    @ViewBuilder let pageContent: (OnboardingStage) -> PageContent

    @State private var scrolledStage: OnboardingStage?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Places the initial stage's page in view on first layout. The
    /// scrollPosition seed alone is dropped when onboarding resumes on a later
    /// page (the track is positioned before the pages take their final size),
    /// so the anchor expresses the same page as a content fraction instead.
    private let initialAnchor: UnitPoint

    init(
        stage: OnboardingStage,
        onNavigate: @escaping (OnboardingStage) -> Void,
        @ViewBuilder pageContent: @escaping (OnboardingStage) -> PageContent
    ) {
        self.stage = stage
        self.onNavigate = onNavigate
        self.pageContent = pageContent
        _scrolledStage = State(initialValue: stage)
        let pageIndex = OnboardingStage.allCases.firstIndex(of: stage) ?? 0
        let lastIndex = max(OnboardingStage.allCases.count - 1, 1)
        initialAnchor = UnitPoint(
            x: CGFloat(pageIndex) / CGFloat(lastIndex),
            y: 0.5
        )
    }

    var body: some View {
        // Pages are sized from the enclosing geometry, not
        // containerRelativeFrame: measuring pages against the scroll container
        // while each page hosts its own vertical ScrollView re-invalidates the
        // container measurement and stalls layout in a feedback loop.
        GeometryReader { geometry in
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(OnboardingStage.allCases, id: \.self) { pageStage in
                        pageContent(pageStage)
                            .frame(
                                width: geometry.size.width,
                                height: geometry.size.height
                            )
                            .clipped()
                            .allowsHitTesting(pageStage == stage)
                            .accessibilityHidden(pageStage != stage)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollIndicators(.hidden)
            .scrollPosition(id: $scrolledStage)
            .defaultScrollAnchor(initialAnchor)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: stage) { _, newStage in
            guard scrolledStage != newStage else { return }
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.32)) {
                scrolledStage = newStage
            }
        }
        .onChange(of: scrolledStage) { _, newValue in
            guard let newValue, newValue != stage else { return }
            onNavigate(newValue)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("MobileOnboardingPageViewport")
    }
}
#endif
