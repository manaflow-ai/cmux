#if os(iOS)
import SwiftUI

/// Abstract product art for notification aggregation. It intentionally avoids
/// mirroring the current feed rows, filters, or tab layout.
struct OnboardingNotificationPreview: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(Color.accentColor.opacity(0.08))
                .frame(width: 218, height: 218)

            Circle()
                .strokeBorder(Color.accentColor.opacity(0.14), style: StrokeStyle(lineWidth: 1, dash: [5, 7]))
                .frame(width: 190, height: 190)

            OnboardingNotificationLink(tint: .blue)
                .rotationEffect(.degrees(31))
                .offset(x: -55, y: -42)
            OnboardingNotificationLink(tint: .indigo)
                .rotationEffect(.degrees(-31))
                .offset(x: 55, y: -42)
            OnboardingNotificationLink(tint: .pink)
                .rotationEffect(.degrees(-32))
                .offset(x: -54, y: 45)

            OnboardingNotificationSource(
                systemImage: "shippingbox.fill",
                tint: .blue
            )
            .offset(x: -112, y: -76)

            OnboardingNotificationSource(
                systemImage: "terminal.fill",
                tint: .indigo
            )
            .offset(x: 112, y: -76)

            OnboardingNotificationSource(
                systemImage: "doc.text.fill",
                tint: .pink
            )
            .offset(x: -108, y: 78)

            OnboardingNotificationDestination()
        }
        .frame(maxWidth: .infinity)
        .frame(height: 232)
        .accessibilityHidden(true)
    }
}

private struct OnboardingNotificationLink: View {
    let tint: Color

    var body: some View {
        Capsule()
            .fill(LinearGradient(
                colors: [tint.opacity(0.42), Color.accentColor.opacity(0.12)],
                startPoint: .leading,
                endPoint: .trailing
            ))
            .frame(width: 92, height: 2)
    }
}

private struct OnboardingNotificationSource: View {
    let systemImage: String
    let tint: Color

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Circle()
                .fill(.regularMaterial)
                .frame(width: 58, height: 58)
                .overlay {
                    Circle()
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                }
                .overlay {
                    Image(systemName: systemImage)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(tint.gradient)
                }

            Circle()
                .fill(tint.gradient)
                .frame(width: 13, height: 13)
                .overlay {
                    Circle()
                        .stroke(Color(uiColor: .systemBackground), lineWidth: 2)
                }
                .offset(x: -1, y: 1)
        }
        .shadow(color: tint.opacity(0.18), radius: 12, y: 6)
    }
}

private struct OnboardingNotificationDestination: View {
    var body: some View {
        Circle()
            .fill(.regularMaterial)
            .frame(width: 116, height: 116)
            .overlay {
                Circle()
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            }
            .overlay {
                Circle()
                    .fill(LinearGradient(
                        colors: [.blue, .indigo],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .frame(width: 78, height: 78)
                    .overlay {
                        Image(systemName: "bell.badge.fill")
                            .font(.system(size: 34, weight: .semibold))
                            .foregroundStyle(.white)
                            .symbolRenderingMode(.monochrome)
                    }
            }
            .shadow(color: Color.indigo.opacity(0.24), radius: 22, y: 10)
    }
}
#endif
