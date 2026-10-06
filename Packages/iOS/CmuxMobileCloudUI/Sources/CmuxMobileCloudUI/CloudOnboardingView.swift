#if os(iOS)
import CmuxMobileCloud
import CmuxMobileSupport
import SwiftUI

/// Explains the Cloud connection before the first machine is opened.
///
/// Visually this is the app's first-run onboarding scene design: the ambient
/// Game of Life backdrop, balanced large-title copy above a symbol visual,
/// capsule page dots, and a prominent capsule primary action. Completion is
/// handled by `onComplete` (inline) or dismissal (sheet), with skipping owned
/// by the surrounding chrome.
public struct CloudOnboardingView: View {
    private let controller: CloudSessionController?
    private let onComplete: (() -> Void)?
    private let showsNavigationChrome: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.cloudSystemVPNController) private var systemVPN
    @State private var page = 0

    private static let pageCount = 3

    /// - Parameters:
    ///   - controller: The Cloud session used by the optional VPN step.
    ///   - onComplete: Called when the user finishes or skips inline onboarding.
    ///     When omitted, the view dismisses itself as a sheet.
    ///   - showsNavigationChrome: Adds a navigation stack and sheet controls.
    ///     Inline onboarding uses the surrounding Cloud tab's navigation stack.
    public init(
        controller: CloudSessionController? = nil,
        onComplete: (() -> Void)? = nil,
        showsNavigationChrome: Bool = true
    ) {
        self.controller = controller
        self.onComplete = onComplete
        self.showsNavigationChrome = showsNavigationChrome
    }

    public var body: some View {
        Group {
            if showsNavigationChrome {
                NavigationStack {
                    onboardingContent
                        .navigationTitle(L10n.string("mobile.cloud.onboarding.title", defaultValue: "Cloud basics"))
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button(L10n.string("mobile.cloud.onboarding.skip", defaultValue: "Skip")) {
                                    complete()
                                }
                            }
                        }
                }
            } else {
                onboardingContent
                    .navigationTitle(L10n.string("mobile.cloud.title", defaultValue: "Cloud"))
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
    }

    private var onboardingContent: some View {
        ZStack {
            CloudOnboardingBackdrop()

            VStack(spacing: 0) {
                CloudOnboardingProgressIndicator(page: page, pageCount: Self.pageCount)
                    .padding(.top, 12)
                    .padding(.bottom, 4)

                TabView(selection: $page) {
                    CloudOnboardingPage(
                        title: L10n.string("mobile.cloud.onboarding.workspace.title", defaultValue: "Your workspace lives in the Cloud"),
                        message: L10n.string(
                            "mobile.cloud.onboarding.workspace.message",
                            defaultValue: "Workspaces keep their terminals, browsers, and coding agents running on a Cloud machine."
                        )
                    ) {
                        CloudOnboardingGraphic(
                            topic: .workspace,
                            accessibilityLabel: L10n.string(
                                "mobile.cloud.onboarding.workspace.visual",
                                defaultValue: "A Cloud machine with multiple workspaces, terminals, and browsers"
                            )
                        )
                    }
                    .tag(0)
                    CloudOnboardingPage(
                        title: L10n.string("mobile.cloud.vpn.title", defaultValue: "System VPN"),
                        message: L10n.string(
                            "mobile.cloud.onboarding.vpn.message",
                            defaultValue: "Turn it on when Safari or another app needs to reach a private service on a Cloud machine."
                        )
                    ) {
                        VStack(spacing: 18) {
                            CloudOnboardingGraphic(
                                topic: .vpn,
                                accessibilityLabel: L10n.string(
                                    "mobile.cloud.onboarding.vpn.visual",
                                    defaultValue: "Safari reaches a private Cloud service through the System VPN"
                                )
                            )
                            if let systemVPN {
                                CloudOnboardingVPNControl(controller: systemVPN)
                            }
                        }
                    }
                    .tag(1)
                    CloudOnboardingPage(
                        title: L10n.string("mobile.cloud.onboarding.key.title", defaultValue: "A private key keeps it private"),
                        message: L10n.string(
                            "mobile.cloud.onboarding.key.message",
                            defaultValue: "cmux keeps this phone's private key in the Keychain. It never leaves the phone."
                        )
                    ) {
                        CloudOnboardingGraphic(
                            topic: .key,
                            accessibilityLabel: L10n.string(
                                "mobile.cloud.onboarding.key.title",
                                defaultValue: "A private key keeps it private"
                            )
                        )
                    }
                    .tag(2)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                CloudOnboardingFooter(
                    primaryTitle: page < Self.pageCount - 1
                        ? L10n.string("mobile.cloud.onboarding.continue", defaultValue: "Continue")
                        : L10n.string("mobile.cloud.onboarding.done", defaultValue: "Get started"),
                    secondaryTitle: page > 0
                        ? L10n.string("mobile.cloud.onboarding.back", defaultValue: "Back")
                        : nil,
                    onPrimary: {
                        if page < Self.pageCount - 1 {
                            withAnimation { page += 1 }
                        } else {
                            complete()
                        }
                    },
                    onSecondary: {
                        withAnimation { page -= 1 }
                    }
                )
            }
        }
    }

    private func complete() {
        if let onComplete {
            onComplete()
        } else {
            dismiss()
        }
    }
}

/// A stationary onboarding page in the first-run scene layout: the copy keeps
/// its intrinsic height and the symbol visual consumes the remaining space.
/// Regular-width, non-accessibility type lays copy and visual side by side.
private struct CloudOnboardingPage<Visual: View>: View {
    let title: String
    let message: String
    let visualContent: Visual

    init(
        title: String,
        message: String,
        @ViewBuilder visual: () -> Visual
    ) {
        self.title = title
        self.message = message
        visualContent = visual()
    }

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if usesWideLayout {
                HStack(alignment: .center, spacing: verticalSizeClass == .compact ? 16 : 48) {
                    copy(alignment: .center)
                        .frame(
                            maxWidth: verticalSizeClass == .compact ? 280 : 390,
                            alignment: .center
                        )
                        .layoutPriority(1)
                    visual
                }
                .padding(.horizontal, verticalSizeClass == .compact ? 16 : 48)
                .padding(.vertical, verticalSizeClass == .compact ? 4 : 32)
                .frame(maxWidth: 980, maxHeight: .infinity, alignment: .center)
            } else {
                VStack(spacing: 18) {
                    copy(alignment: .center)
                        .frame(maxWidth: 560, alignment: .center)
                        .layoutPriority(1)
                    visual
                }
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 8)
                .frame(maxWidth: 620, maxHeight: .infinity, alignment: .center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .accessibilityElement(children: .combine)
    }

    private var usesWideLayout: Bool {
        verticalSizeClass == .compact
            || (horizontalSizeClass == .regular && !dynamicTypeSize.isAccessibilitySize)
    }

    private func copy(alignment: TextAlignment) -> some View {
        VStack(alignment: alignment == .leading ? .leading : .center, spacing: 12) {
            Text(title)
                .font(.largeTitle.bold())
                .multilineTextAlignment(alignment)
                .fixedSize(horizontal: false, vertical: true)
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(alignment)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .center)
    }

    private var visual: some View {
        visualContent
            .frame(maxWidth: 520, maxHeight: 280, alignment: .center)
            .accessibilityHidden(true)
    }
}

private struct CloudOnboardingGraphic: View {
    enum Topic: String {
        case workspace
        case vpn
        case key

        var symbolName: String {
            switch self {
            case .workspace: "cloud.fill"
            case .vpn: "lock.shield.fill"
            case .key: "key.fill"
            }
        }

        var tint: Color {
            switch self {
            case .workspace: .blue
            case .vpn: .green
            case .key: .purple
            }
        }
    }

    let topic: Topic
    let accessibilityLabel: String

    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(topic.tint.opacity(0.14))

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(topic.tint.opacity(0.3), lineWidth: 1)

            Image(systemName: topic.symbolName)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: iconSize, weight: .medium))
                .foregroundStyle(topic.tint)
        }
        .frame(width: dimension, height: dimension)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isImage)
        .accessibilityIdentifier("CloudOnboardingGraphic-\(topic.rawValue)")
    }

    private var dimension: CGFloat {
        verticalSizeClass == .compact ? 112 : 176
    }

    private var iconSize: CGFloat {
        verticalSizeClass == .compact ? 42 : 68
    }

    private var cornerRadius: CGFloat {
        verticalSizeClass == .compact ? 24 : 30
    }
}

private struct CloudOnboardingVPNControl: View {
    let controller: CloudSystemVPNController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(
                get: { controller.phase.isRequestedOn },
                set: { $0 ? controller.enable() : controller.disable() }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.string("mobile.cloud.vpn.title", defaultValue: "System VPN"))
                    Text(statusText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!controller.isAvailable || controller.phase.isTransitioning)
            .accessibilityIdentifier("CloudOnboardingVPNToggle")

            Text(controller.isAvailable
                ? L10n.string(
                    "mobile.cloud.onboarding.vpn.controlFooter",
                    defaultValue: "You can change this later in Cloud settings."
                )
                : L10n.string(
                    "mobile.cloud.vpn.deviceRequired",
                    defaultValue: "System VPN needs a physical iPhone or iPad."
                ))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var statusText: String {
        switch controller.phase {
        case .off, .failed:
            L10n.string("mobile.cloud.vpn.status.off", defaultValue: "Off")
        case .preparing:
            L10n.string("mobile.cloud.vpn.status.preparing", defaultValue: "Setting up...")
        case .connecting:
            L10n.string("mobile.cloud.vpn.status.connecting", defaultValue: "Connecting...")
        case .connected:
            L10n.string("mobile.cloud.vpn.status.connected", defaultValue: "Connected")
        case .disconnecting:
            L10n.string("mobile.cloud.vpn.status.disconnecting", defaultValue: "Disconnecting...")
        }
    }
}

/// The scene's capsule page dots: the current page reads as a wide accent
/// capsule, the rest as small neutral dots, over an elliptical background
/// wash so the backdrop cells never read as extra pages.
private struct CloudOnboardingProgressIndicator: View {
    let page: Int
    let pageCount: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<pageCount, id: \.self) { item in
                Capsule()
                    .fill(item == page ? Color.accentColor : Color.secondary.opacity(0.24))
                    .frame(width: item == page ? 22 : 7, height: 7)
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: page)
        .background {
            EllipticalGradient(
                colors: [
                    Color(uiColor: .systemBackground),
                    Color(uiColor: .systemBackground),
                    Color(uiColor: .systemBackground).opacity(0),
                ],
                center: .center
            )
            .frame(width: 200, height: 44)
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.string(
            "mobile.cloud.onboarding.progressLabel",
            defaultValue: "Cloud introduction progress"
        ))
        .accessibilityValue(String(
            format: L10n.string(
                "mobile.onboarding.progressFormat",
                defaultValue: "Step %1$d of %2$d"
            ),
            page + 1,
            pageCount
        ))
        .accessibilityIdentifier("CloudOnboardingProgressIndicator")
    }
}

/// The scene footer: a prominent capsule primary action above a plain text
/// secondary. The secondary slot is reserved even when empty so the page
/// visual keeps one size across pages; compact height lays the actions side
/// by side instead.
private struct CloudOnboardingFooter: View {
    let primaryTitle: String
    let secondaryTitle: String?
    let onPrimary: () -> Void
    let onSecondary: () -> Void

    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        Group {
            if verticalSizeClass == .compact {
                HStack(spacing: 12) {
                    actions
                }
            } else {
                VStack(spacing: 10) {
                    actions
                }
            }
        }
        .frame(maxWidth: 520)
        .padding(.horizontal, 24)
        .padding(.top, verticalSizeClass == .compact ? 8 : 16)
        .padding(.bottom, verticalSizeClass == .compact ? 8 : 12)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("CloudOnboardingFooter")
    }

    @ViewBuilder
    private var actions: some View {
        Button(action: onPrimary) {
            Text(primaryTitle)
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity)
                .contentShape(.capsule)
        }
        .mobileGlassProminentButton()
        .accessibilityIdentifier("CloudOnboardingPrimaryButton")

        if secondaryTitle != nil || verticalSizeClass != .compact {
            // Reserve the control's size, including system button padding, so
            // the pager height never jumps when Back appears on later pages.
            Button(
                secondaryTitle ?? L10n.string("mobile.cloud.onboarding.back", defaultValue: "Back"),
                action: onSecondary
            )
            .font(.subheadline.weight(.medium))
            .frame(maxWidth: verticalSizeClass == .compact ? .infinity : nil)
            .frame(minHeight: 44)
            .opacity(secondaryTitle == nil ? 0 : 1)
            .disabled(secondaryTitle == nil)
            .accessibilityHidden(secondaryTitle == nil)
            .accessibilityIdentifier("CloudOnboardingSecondaryButton")
        }
    }
}
#endif
