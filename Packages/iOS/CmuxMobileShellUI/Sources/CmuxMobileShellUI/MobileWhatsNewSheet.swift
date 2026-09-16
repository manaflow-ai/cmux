#if os(iOS)
import CmuxMobileSupport
import SwiftUI

/// One-time What's New sheet shown on the first launch after an update, for
/// users who already have Computers (fresh installs learn the same things in
/// onboarding). Shows every unseen page newest first; a user who skipped
/// several updates gets one sheet covering all of them. Every page stays
/// readable later in Settings > What's New.
///
/// Native pages report their natural height independently of the viewport.
/// The selected page owns the sheet height, including during catch-up swipes.
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pageHeights: [String: CGFloat] = [:]
    @State private var footerHeight: CGFloat = 0
    @State private var detents: Set<PresentationDetent> = [.large]
    @State private var selectedDetent: PresentationDetent = .large

    private var usesFullHeight: Bool {
        if dynamicTypeSize.isAccessibilitySize { return true }
        switch selectedPage?.body {
        case .web:
            return true
        default:
            break
        }
        return false
    }

    private var selectedPage: MobileWhatsNewPage? {
        pages.indices.contains(pageIndex) ? pages[pageIndex] : nil
    }

    private var pageHeight: CGFloat? {
        guard !usesFullHeight, let selectedPage else { return nil }
        return pageHeights[selectedPage.listID]
    }

    private var contentHeight: CGFloat? {
        pageHeight.map { $0 + footerHeight }
    }

    private var selection: Binding<Int> {
        Binding(get: { pageIndex }, set: { index in
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) {
                pageIndex = index
            }
        })
    }

    var body: some View {
        VStack(spacing: 0) {
            if pages.count > 1 {
                TabView(selection: selection) {
                    ForEach(Array(pages.enumerated()), id: \.element.listID) { index, page in
                        measuredPage(page)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .always))
                .frame(idealHeight: pageHeight, maxHeight: pageHeight, alignment: .top)
            } else if let page = pages.first {
                measuredPage(page)
                    .frame(idealHeight: pageHeight, maxHeight: pageHeight, alignment: .top)
            }
            continueButton
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    footerHeight = height
                }
        }
        .frame(idealWidth: 608, maxWidth: 608)
        .background(PlatformPalette.systemBackground)
        .accessibilityIdentifier("MobileWhatsNewSheet")
        .presentationSizing(.fitted)
        .presentationDetents(detents, selection: $selectedDetent)
        .onChange(of: contentHeight, initial: true) { _, height in
            resizeSheet(to: height)
        }
        .presentationContentInteraction(.scrolls)
        .presentationDragIndicator(.visible)
    }

    private func resizeSheet(to height: CGFloat?) {
        let target = height.map { PresentationDetent.height($0) } ?? .large
        guard target != selectedDetent else { return }
        // Both endpoints must exist while the system animates its selection.
        detents.insert(target)
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.3), completionCriteria: .removed) {
            selectedDetent = target
        } completion: {
            guard selectedDetent == target else { return }
            detents = [target]
        }
    }

    @ViewBuilder
    private func measuredPage(_ page: MobileWhatsNewPage) -> some View {
        switch page.body {
        case .features, .pairingSetup:
            ScrollView {
                MobileWhatsNewContent(page: page, layout: .compact)
                    .fixedSize(horizontal: false, vertical: true)
                    // Leave space for the system page control inside TabView.
                    .padding(.bottom, pages.count > 1 ? 36 : 0)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        guard height.isFinite, height > 0 else { return }
                        withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) {
                            pageHeights[page.listID] = height
                        }
                    }
            }
            .scrollBounceBehavior(.basedOnSize)
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
            selection.wrappedValue += 1
        } else {
            dismiss()
        }
    }
}
#endif
