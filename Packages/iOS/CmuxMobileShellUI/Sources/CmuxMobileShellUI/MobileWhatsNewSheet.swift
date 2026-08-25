#if os(iOS)
import CmuxMobileSupport
import SwiftUI

/// One-time What's New sheet shown on the first launch after an update, for
/// users who already have Computers (fresh installs learn the same things in
/// onboarding). Shows every unseen page newest first; a user who skipped
/// several updates gets one sheet covering all of them. Every page stays
/// readable later in Settings > What's New.
struct MobileWhatsNewSheet: View {
    let pages: [MobileWhatsNewPage]
    let allowedWebHosts: Set<String>
    let dismiss: () -> Void
    @State private var pageIndex = 0

    var body: some View {
        VStack(spacing: 0) {
            if pages.count > 1 {
                TabView(selection: $pageIndex) {
                    ForEach(Array(pages.enumerated()), id: \.element.listID) { index, page in
                        pageView(page)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .always))
            } else if let page = pages.first {
                pageView(page)
            }
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
            .padding(.bottom, 16)
        }
        .background(PlatformPalette.systemBackground)
        .accessibilityIdentifier("MobileWhatsNewSheet")
    }

    @ViewBuilder
    private func pageView(_ page: MobileWhatsNewPage) -> some View {
        switch page.body {
        case .features:
            ScrollView {
                MobileWhatsNewContent(page: page)
            }
        case .web(let url):
            MobileWhatsNewWebView(url: url, allowedHosts: allowedWebHosts)
        }
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
#endif
