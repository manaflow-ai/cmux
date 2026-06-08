#if os(iOS)
import SwiftUI

/// Renders a single ``OnboardingPage``: a centered SF Symbol, a title, a body,
/// and an optional inline link (used by the Tailscale page to point at the
/// install page).
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

                if let link = page.link {
                    Link(destination: link.url) {
                        Label(link.title, systemImage: "arrow.up.right.square")
                            .font(.callout.weight(.medium))
                    }
                    .accessibilityIdentifier("MobileOnboardingLink")
                }

                Spacer(minLength: 24)
            }
            .padding(.horizontal, 28)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
        .accessibilityElement(children: .contain)
    }
}
#endif
