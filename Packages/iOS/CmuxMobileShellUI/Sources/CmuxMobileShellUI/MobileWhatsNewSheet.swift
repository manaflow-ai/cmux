#if os(iOS)
import CmuxMobileSupport
import SwiftUI

/// One-time What's New sheet shown on the first launch after an update, for
/// users who already have Computers (fresh installs learn the same things in
/// onboarding). Shows every unseen page newest first; a user who skipped
/// several updates gets one sheet covering all of them. Every page stays
/// readable later in Settings > What's New.
///
/// The common single-page case renders as a compact, content-fitted card
/// (owner contract: no scrolling at standard type sizes on any iPhone and no
/// trailing white space); the Auto-Connect migration sheet pioneered the
/// measurement mechanics. Accessibility type sizes, web pages, and the
/// multi-page catch-up keep a full-height sheet, where scrolling is the
/// correct behavior.
struct MobileWhatsNewSheet: View {
    let pages: [MobileWhatsNewPage]
    let allowedWebHosts: Set<String>
    /// Web pages are preloaded before this sheet presents (keyed by
    /// `listID`), so a web page renders the instant the sheet appears
    /// instead of loading behind an already-visible sheet.
    var webLoads: [String: MobileWhatsNewWebPageLoad] = [:]
    let dismiss: () -> Void
    @State private var pageIndex = 0
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var contentHeight: CGFloat = 1

    /// Fixed-viewport presentations: the TabView catch-up and web pages need
    /// full height, and accessibility sizes legitimately scroll.
    private var usesFullHeight: Bool {
        if dynamicTypeSize.isAccessibilitySize { return true }
        if pages.count > 1 { return true }
        if case .web = pages.first?.body { return true }
        return false
    }

    var body: some View {
        Group {
            if pages.count > 1 {
                VStack(spacing: 0) {
                    TabView(selection: $pageIndex) {
                        ForEach(Array(pages.enumerated()), id: \.element.listID) { index, page in
                            fullHeightPage(page)
                                .tag(index)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .always))
                    .indexViewStyle(.page(backgroundDisplayMode: .always))
                    continueButton
                }
            } else if let page = pages.first {
                switch page.body {
                case .features where !dynamicTypeSize.isAccessibilitySize:
                    // Content-fitted card: compact density measured at its
                    // natural height; the scroll tier only takes over when
                    // the screen caps the sheet below that height (short
                    // landscape phones), never in portrait at standard type.
                    ViewThatFits(in: .vertical) {
                        measuredSinglePage(page)
                        ScrollView {
                            measuredSinglePage(page)
                        }
                        .scrollBounceBehavior(.basedOnSize)
                    }
                default:
                    VStack(spacing: 0) {
                        fullHeightPage(page)
                        continueButton
                    }
                }
            }
        }
        .background(PlatformPalette.systemBackground)
        .accessibilityIdentifier("MobileWhatsNewSheet")
        .modifier(MobileWhatsNewPresentationSizing(
            contentHeight: contentHeight,
            usesFullHeight: usesFullHeight
        ))
    }

    /// The measured single-page body: content at natural height (fixedSize)
    /// plus the Continue button, reported to drive the fitted detent. The
    /// report is proposal-independent, so the detent cannot oscillate.
    private func measuredSinglePage(_ page: MobileWhatsNewPage) -> some View {
        VStack(spacing: 0) {
            MobileWhatsNewContent(page: page, layout: .compact)
                .fixedSize(horizontal: false, vertical: true)
            continueButton
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { newHeight in
            guard newHeight.isFinite, newHeight > 0 else { return }
            contentHeight = newHeight
        }
    }

    @ViewBuilder
    private func fullHeightPage(_ page: MobileWhatsNewPage) -> some View {
        switch page.body {
        case .features:
            MobileWhatsNewFittingPage(page: page)
        case .web(let url):
            MobileWhatsNewWebView(
                url: url,
                allowedHosts: allowedWebHosts,
                preloadedLoad: webLoads[page.listID]
            )
        }
    }

    private var continueButton: some View {
        Button(action: advance) {
            Text(L10n.string(
                "mobile.whatsNew.cta",
                defaultValue: "Continue"
            ))
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(.blue)
        .accessibilityIdentifier("MobileWhatsNewContinue")
        .padding(.horizontal, 24)
        .padding(.top, 4)
        .padding(.bottom, 16)
    }

    /// Continue advances through unseen pages and dismisses from the last
    /// one. Acknowledgement already happened when the sheet first showed, so
    /// dismissing early (swipe) skips content but never re-shows it.
    private func advance() {
        if pageIndex < pages.count - 1 {
            withAnimation {
                pageIndex += 1
            }
        } else {
            dismiss()
        }
    }
}

/// Fits the sheet to its measured content height for the common single-page
/// standard-type case; full height only where a fixed viewport is required.
private struct MobileWhatsNewPresentationSizing: ViewModifier {
    let contentHeight: CGFloat
    let usesFullHeight: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if usesFullHeight {
            content
                .presentationDetents([.large])
        } else {
            content
                .presentationSizing(.fitted)
                .presentationDetents([.height(contentHeight)])
        }
    }
}
#endif
