#if os(iOS)
import CmuxMobileDesign
import SwiftUI

private let theme = CmuxMobileTheme.standard

/// Real cmux notifications as Notification Center draws them: a screenshot from a
/// simulator that received three pushes through the app's own service extension
/// (`OnboardingPushShotUITests`, fleet step efc57995fafc6405ff516529), cropped to the
/// three cmux notifications and shown with rounded corners. One image serves both
/// appearances: the lock screen's glass draws the same in light and dark. Not a drawing: what the person will get.
struct NotificationsShot: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)
        Image("OnboardingPushes", bundle: .module)
            .resizable()
            .scaledToFit()
            .clipShape(shape)
            .overlay(shape.strokeBorder(theme.colors.separator.color, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
            .frame(maxWidth: 340)
            .accessibilityElement()
            .accessibilityLabel(Text("cmux notifications: Codex asks to run git push origin feat-onboarding, Claude Code finished fixing the failing auth tests, and Chief says the nightly is green again"))
            .accessibilityIdentifier("setup.notifications.shot")
    }
}
#endif
