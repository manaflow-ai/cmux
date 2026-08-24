#if os(iOS)
import CmuxMobileSupport
import SwiftUI
import UIKit

/// A Lock Screen replica inside the shared iPhone product frame showing a cmux
/// agent notification with its inline reply bar. The reply text types itself in
/// a loop so people see they can answer an agent without opening the app; the
/// bar is always laid out so page frames stay stable for UI tests, and Reduce
/// Motion renders the finished reply statically.
struct OnboardingPushPreview: View {
    let accessibilityLabel: String

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var deviceFrame: UIImage?
    @State private var screenMask: UIImage?
    @State private var typedCharacterCount = 0
    @State private var isShowingSentPulse = false

    private static let typingClock = ContinuousClock()

    /// The lock screen lays out once at this fixed design size (the portrait
    /// screen slot, matching the product frame's screen aspect ratio) and is
    /// scale-transformed into whatever slot the page offers. Text has a fixed
    /// intrinsic height, so laying it out directly in a short landscape slot
    /// would overflow the device frame and the page viewport; a raster
    /// screenshot never has that problem, and this keeps the same guarantee.
    private static let lockScreenDesignSize = CGSize(
        width: 246,
        height: 246 * 2868 / 1320
    )

    var body: some View {
        OnboardingIPhoneScreenshotFrame(
            preferredHeight: preferredFrameHeight,
            deviceFrame: deviceFrame,
            screenMask: screenMask
        ) {
            GeometryReader { proxy in
                lockScreen
                    .frame(
                        width: Self.lockScreenDesignSize.width,
                        height: Self.lockScreenDesignSize.height
                    )
                    .scaleEffect(
                        proxy.size.width / Self.lockScreenDesignSize.width,
                        anchor: .topLeading
                    )
            }
            .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: preferredFrameHeight, alignment: .top)
        .opacity(imagesAreReady ? 1 : 0)
        .accessibilityElement()
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(
            imagesAreReady
                ? "MobileOnboardingPushPreview"
                : "MobileOnboardingPushPreview-loading"
        )
        .task(id: appearance) {
            let loadedDeviceFrame = await OnboardingScreenshot.deviceFrameImage(
                appearance: appearance
            )
            let loadedScreenMask = await OnboardingScreenshot.screenMaskImage()
            guard !Task.isCancelled else { return }
            deviceFrame = loadedDeviceFrame
            screenMask = loadedScreenMask
        }
        .task(id: reduceMotion) {
            await runTypingLoop()
        }
    }

    /// The device screen: a dark Lock Screen with the time, one cmux agent
    /// notification, and the expanded inline reply bar beneath it.
    private var lockScreen: some View {
        VStack(spacing: 14) {
            // Apple's canonical marketing time; deterministic for screenshots.
            Text(verbatim: "9:41")
                .font(.system(size: 56, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.95))
                .padding(.top, 48)

            notificationCard
            replyBar

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            LinearGradient(
                colors: [
                    Color(red: 0.09, green: 0.12, blue: 0.24),
                    Color(red: 0.03, green: 0.04, blue: 0.10),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .environment(\.colorScheme, .dark)
        .dynamicTypeSize(.large)
    }

    private var notificationCard: some View {
        HStack(alignment: .top, spacing: 10) {
            agentIcon

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    // The sending agent's process name is data, not UI copy.
                    Text(verbatim: "claude")
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 8)
                    Text(L10n.string(
                        "mobile.onboarding.push.previewTime",
                        defaultValue: "now"
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Text(verbatim: "issue-4821")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(L10n.string(
                    "mobile.onboarding.push.previewBody",
                    defaultValue: "Tests are green. Merge it?"
                ))
                .font(.footnote)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.white.opacity(0.14))
        )
    }

    private var agentIcon: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.black)
            .frame(width: 36, height: 36)
            .overlay {
                Text(verbatim: ">_")
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.white.opacity(0.25), lineWidth: 0.5)
            }
    }

    /// The inline reply bar. The typed text and the placeholder are both always
    /// laid out (opacity-swapped) so the capsule never changes size mid-loop.
    private var replyBar: some View {
        HStack(spacing: 8) {
            ZStack(alignment: .leading) {
                Text(Self.replyPlaceholder)
                    .foregroundStyle(.secondary)
                    .opacity(visibleReplyText.isEmpty ? 1 : 0)
                Text(visibleReplyText)
                    .foregroundStyle(.primary)
            }
            .font(.footnote)
            .lineLimit(1)

            Spacer(minLength: 8)

            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(
                    replyIsComplete || isShowingSentPulse
                        ? AnyShapeStyle(Color.accentColor)
                        : AnyShapeStyle(.secondary)
                )
                .accessibilityLabel(Self.replySendTitle)
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(height: 40)
        .background(Capsule().fill(.white.opacity(0.14)))
    }

    private var visibleReplyText: String {
        if reduceMotion { return Self.replyText }
        if isShowingSentPulse { return "" }
        return String(Self.replyText.prefix(typedCharacterCount))
    }

    private var replyIsComplete: Bool {
        reduceMotion || typedCharacterCount >= Self.replyText.count
    }

    /// One demonstration cycle: rest on the placeholder, type the reply, hold
    /// it, pulse the send arrow, and clear. Every wait is a cancellation-aware
    /// clock sleep tied to the view's `.task` lifetime.
    private func runTypingLoop() async {
        if reduceMotion {
            typedCharacterCount = Self.replyText.count
            isShowingSentPulse = false
            return
        }
        typedCharacterCount = 0
        isShowingSentPulse = false
        let characterCount = Self.replyText.count
        guard characterCount > 0 else { return }
        let clock = Self.typingClock
        while !Task.isCancelled {
            guard (try? await clock.sleep(for: .milliseconds(900))) != nil else { return }
            for count in 1...characterCount {
                typedCharacterCount = count
                guard (try? await clock.sleep(for: .milliseconds(70))) != nil else { return }
            }
            guard (try? await clock.sleep(for: .milliseconds(900))) != nil else { return }
            isShowingSentPulse = true
            guard (try? await clock.sleep(for: .milliseconds(600))) != nil else { return }
            isShowingSentPulse = false
            typedCharacterCount = 0
        }
    }

    private var imagesAreReady: Bool {
        deviceFrame != nil && screenMask != nil
    }

    private var preferredFrameHeight: CGFloat {
        if dynamicTypeSize.isAccessibilitySize {
            return 360
        }
        return horizontalSizeClass == .regular ? 700 : 560
    }

    private var appearance: OnboardingScreenshotAppearance {
        OnboardingScreenshotAppearance.resolve(colorScheme: colorScheme)
    }

    private static var replyText: String {
        L10n.string(
            "mobile.onboarding.push.previewReply",
            defaultValue: "Merge it"
        )
    }

    /// The real inline-reply strings from the notification category, so the
    /// preview matches what the OS shows (package catalog, `.module`).
    private static var replyPlaceholder: String {
        String(
            localized: "mobile.push.reply.placeholder",
            defaultValue: "Message the agent…",
            bundle: .module
        )
    }

    private static var replySendTitle: String {
        String(
            localized: "mobile.push.reply.send",
            defaultValue: "Send",
            bundle: .module
        )
    }
}
#endif
