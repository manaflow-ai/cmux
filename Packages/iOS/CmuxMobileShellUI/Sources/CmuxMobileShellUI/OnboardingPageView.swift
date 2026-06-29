#if os(iOS)
import SwiftUI

/// Renders a single ``OnboardingPage``: a centered SF Symbol, a title, a body, an
/// optional left-aligned checklist (used by the Tailscale set-up page), and any
/// inline links (e.g. the Tailscale App Store and Mac download links).
struct OnboardingPageView: View {
    let page: OnboardingPage

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Spacer(minLength: 24)

                Image(systemName: page.systemImage)
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(.tint)
                    .symbolRenderingMode(.hierarchical)
                    .accessibilityHidden(true)
                    .padding(.bottom, 4)

                VStack(spacing: 14) {
                    Text(page.title)
                        .font(.title)
                        .fontWeight(.bold)
                        .multilineTextAlignment(.center)

                    Text(page.body)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !page.checklist.isEmpty {
                    checklist
                }

                if !page.links.isEmpty {
                    VStack(spacing: 10) {
                        ForEach(Array(page.links.enumerated()), id: \.offset) { index, link in
                            Link(destination: link.url) {
                                Label(link.title, systemImage: "arrow.up.right.square")
                                    .font(.callout.weight(.medium))
                            }
                            .accessibilityIdentifier(index == 0 ? "MobileOnboardingLink" : "MobileOnboardingLink\(index)")
                        }
                    }
                }

                Spacer(minLength: 24)
            }
            .padding(.horizontal, 28)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
        .accessibilityElement(children: .contain)
    }

    private var checklist: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(page.checklist.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    Text(item)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("MobileOnboardingChecklist")
    }
}
#endif
