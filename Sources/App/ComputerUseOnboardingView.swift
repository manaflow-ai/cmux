import AppKit
import SwiftUI

/// Non-blocking, one-permission-at-a-time onboarding for local computer use.
///
/// Permissions belong to the standalone `cmux Computer Use` helper. Each step
/// opens the matching System Settings pane, offers the helper as a real file-URL
/// drag source, and refreshes status from the helper's own TCC identity.
@MainActor
struct ComputerUseOnboardingView: View {
    static let initialStep = 0

    let runtimeService: ComputerUseRuntimeService
    let initialStep: Int
    let onSystemSettingsOpened: @MainActor () -> Void
    let onExpandedRequested: @MainActor () -> Void
    let onClose: () -> Void

    @State private var step: Int
    @State private var accessibilityGranted = false
    @State private var screenRecordingGranted = false
    @State private var refreshInFlight = false
    @State private var permissionCheckArmed = false
    @State private var helperAppURL: URL?
    @State private var helperIcon: NSImage?
    @State private var isPermissionCompanionVisible: Bool
    @State private var initialPermissionFlowStarted = false
    @State private var permissionSetupInFlight = false

    init(
        runtimeService: ComputerUseRuntimeService,
        initialStep: Int = 0,
        onSystemSettingsOpened: @escaping @MainActor () -> Void = {},
        onExpandedRequested: @escaping @MainActor () -> Void = {},
        onClose: @escaping () -> Void
    ) {
        self.runtimeService = runtimeService
        self.initialStep = initialStep
        self.onSystemSettingsOpened = onSystemSettingsOpened
        self.onExpandedRequested = onExpandedRequested
        self.onClose = onClose
        _step = State(initialValue: initialStep)
        _isPermissionCompanionVisible = State(initialValue: false)
    }

    var body: some View {
        Group {
            if isPermissionCompanionVisible {
                permissionCompanion
            } else {
                expandedOnboarding
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(onboardingBackground)
        .preferredColorScheme(.dark)
        .onAppear {
            prepareHelperForOnboarding()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard permissionCheckArmed else { return }
            permissionCheckArmed = false
            refreshPermissions()
        }
    }

    private var onboardingBackground: Color {
        Color(nsColor: .windowBackgroundColor)
    }

    /// The reference-style overview shown before entering a macOS permission pane.
    private var expandedOnboarding: some View {
        ZStack(alignment: .top) {
            onboardingBackground

            VStack(spacing: 0) {
                helperHeroIcon
                    .padding(.top, 68)

                Text(String(
                    localized: "computerUse.onboarding.hero.title",
                    defaultValue: "Enable cmux Computer Use"
                ))
                .font(.system(size: 38, weight: .bold))
                .padding(.top, 24)

                Text(String(
                    localized: "computerUse.onboarding.hero.detail",
                    defaultValue: "cmux Computer Use needs these permissions to use apps on your Mac.\nThese permissions are used when you ask an agent to perform tasks."
                ))
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 20)

                permissionOverview
                    .padding(.top, 34)

                Spacer(minLength: 34)
            }
            .padding(.horizontal, 52)

            ComputerUseWindowDragRegion()
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .accessibilityHidden(true)
        }
        .frame(width: 900, height: 665)
    }

    private var helperHeroIcon: some View {
        Group {
            if let helperIcon {
                Image(nsImage: helperIcon)
                    .resizable()
                    .interpolation(.high)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 20)
                        .fill(Color.accentColor.gradient)
                    Image(systemName: "cursorarrow.motionlines")
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: 86, height: 86)
        .shadow(color: .black.opacity(0.28), radius: 14, y: 8)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var permissionOverview: some View {
        VStack(spacing: 18) {
            if accessibilityGranted {
                completedPermissionCard(
                    symbolName: "accessibility",
                    title: String(
                        localized: "computerUse.onboarding.accessibility.short",
                        defaultValue: "Accessibility"
                    ),
                    detail: String(
                        localized: "computerUse.onboarding.accessibility.cardDetail",
                        defaultValue: "Allows cmux Computer Use to access app interfaces"
                    ),
                    tint: .blue
                )
            }

            if screenRecordingGranted {
                completedPermissionCard(
                    symbolName: "rectangle.inset.filled.and.person.filled",
                    title: String(
                        localized: "computerUse.onboarding.screenRecording.short",
                        defaultValue: "Screen Recording"
                    ),
                    detail: String(
                        localized: "computerUse.onboarding.screenRecording.cardDetail",
                        defaultValue: "Allows cmux Computer Use to see app windows and screen content"
                    ),
                    tint: .indigo
                )
            }

            if let pendingPermissionStep {
                pendingPermissionCard(permissionStep: pendingPermissionStep)
            } else {
                Button(
                    String(localized: "computerUse.onboarding.done", defaultValue: "Done"),
                    action: onClose
                )
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 2)
            }
        }
    }

    private func completedPermissionCard(
        symbolName: String,
        title: String,
        detail: String,
        tint: Color
    ) -> some View {
        HStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(tint.gradient)
                Circle()
                    .strokeBorder(.white.opacity(0.7), lineWidth: 3)
                Image(systemName: symbolName)
                    .font(.system(size: 38, weight: .medium))
                    .foregroundStyle(.white)
            }
            .frame(width: 78, height: 78)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 7) {
                Text(title)
                    .font(.system(size: 23, weight: .bold))
                Text(detail)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 24)

            HStack(spacing: 9) {
                Text(String(localized: "computerUse.onboarding.done", defaultValue: "Done"))
                    .font(.system(size: 18, weight: .bold))
                Image(systemName: "checkmark")
                    .font(.system(size: 17, weight: .semibold))
            }
            .foregroundStyle(.primary)
        }
        .padding(.horizontal, 24)
        .frame(height: 118)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 32))
        .overlay {
            RoundedRectangle(cornerRadius: 32)
                .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1.5)
        }
    }

    private func pendingPermissionCard(permissionStep: Int) -> some View {
        let title = permissionStep == 1
            ? String(
                localized: "computerUse.onboarding.accessibility.short",
                defaultValue: "Accessibility"
            )
            : String(
                localized: "computerUse.onboarding.screenRecording.short",
                defaultValue: "Screen Recording"
            )
        let label = helperAppURL == nil
            ? String(
                localized: "computerUse.onboarding.preparingHelper",
                defaultValue: "Preparing cmux Computer Use…"
            )
            : String(
                localized: "computerUse.onboarding.completeInSystemSettings",
                defaultValue: "Complete \(title) in System Settings"
            )

        return Button {
            beginPermissionSetup(for: permissionStep)
        } label: {
            HStack(spacing: 12) {
                if helperAppURL == nil {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(label.uppercased())
                    .font(.system(size: 17, weight: .bold))
                    .tracking(1.2)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 114)
            .contentShape(RoundedRectangle(cornerRadius: 32))
        }
        .buttonStyle(.plain)
        .disabled(helperAppURL == nil || permissionSetupInFlight)
        .overlay {
            RoundedRectangle(cornerRadius: 32)
                .strokeBorder(
                    Color.secondary.opacity(0.38),
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 9])
                )
        }
        .accessibilityHint(String(
            localized: "computerUse.onboarding.openSystemSettings",
            defaultValue: "Open System Settings"
        ))
    }

    private var pendingPermissionStep: Int? {
        if !accessibilityGranted { return 1 }
        if !screenRecordingGranted { return 2 }
        return nil
    }

    private var permissionCompanion: some View {
        Group {
            if step >= 3 {
                permissionCompanionReady
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .center, spacing: 13) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)
                        Text(permissionCompanionInstruction)
                            .font(.title3.weight(.bold))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                    }

                    helperDragTile

                    HStack(spacing: 10) {
                        Button {
                            isPermissionCompanionVisible = false
                            onExpandedRequested()
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 12, weight: .semibold))
                                .frame(width: 28, height: 28)
                                .background(Color.secondary.opacity(0.12), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .help(String(localized: "computerUse.onboarding.back", defaultValue: "Back"))
                        .accessibilityLabel(String(localized: "computerUse.onboarding.back", defaultValue: "Back"))

                        Button(
                            String(
                                localized: "computerUse.onboarding.openSystemSettings",
                                defaultValue: "Open System Settings"
                            )
                        ) {
                            beginPermissionSetup(for: step)
                        }

                        Spacer()
                        permissionStatus(granted: currentPermissionGranted)
                        Button(
                            refreshInFlight
                                ? String(localized: "computerUse.onboarding.checking", defaultValue: "Checking…")
                                : String(localized: "computerUse.onboarding.checkAgain", defaultValue: "Check Again"),
                            action: refreshPermissions
                        )
                        .disabled(refreshInFlight)
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(20)
        .frame(width: 680, height: 250)
    }

    /// A file-URL drag source accepted by the macOS permission lists.
    private var helperDragTile: some View {
        HStack(spacing: 14) {
            Group {
                if let helperIcon {
                    Image(nsImage: helperIcon)
                        .resizable()
                        .frame(width: 48, height: 48)
                } else {
                    Image(systemName: "app.dashed")
                        .font(.system(size: 32))
                        .frame(width: 48, height: 48)
                }
            }
            .accessibilityHidden(true)

            Text(runtimeService.applicationName)
                .font(.body.weight(.semibold))
            Spacer(minLength: 8)
            Label(
                String(localized: "computerUse.onboarding.dragAction", defaultValue: "Drag"),
                systemImage: "hand.draw.fill"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.accentColor.opacity(0.1), in: Capsule())
        }
        .padding(.horizontal, 15)
        .frame(height: 78)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(Color.accentColor.opacity(0.34), lineWidth: 1.5)
        }
        .contentShape(RoundedRectangle(cornerRadius: 18))
        .overlay {
            ComputerUseAppDragSource(
                helperAppURL: helperAppURL,
                helperIcon: helperIcon,
                onDragEnded: handleHelperDragEnded
            )
            .accessibilityHidden(true)
            .allowsHitTesting(helperAppURL != nil)
        }
        .help(String(
            localized: "computerUse.onboarding.dragTooltip",
            defaultValue: "Drag \(runtimeService.applicationName) into the permission list"
        ))
        .opacity(helperAppURL == nil ? 0.55 : 1)
    }

    private var permissionCompanionReady: some View {
        HStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 42, weight: .medium))
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 10) {
                Text(String(
                    localized: "computerUse.onboarding.done.title",
                    defaultValue: "Computer Use Is Ready"
                ))
                .font(.title2.weight(.semibold))
                HStack(spacing: 8) {
                    permissionStatus(
                        granted: accessibilityGranted,
                        label: String(
                            localized: "computerUse.onboarding.accessibility.short",
                            defaultValue: "Accessibility"
                        )
                    )
                    permissionStatus(
                        granted: screenRecordingGranted,
                        label: String(
                            localized: "computerUse.onboarding.screenRecording.short",
                            defaultValue: "Screen Recording"
                        )
                    )
                }
            }
            Spacer()
            Button(
                String(localized: "computerUse.onboarding.done", defaultValue: "Done"),
                action: onClose
            )
            .buttonStyle(.borderedProminent)
        }
    }

    private var permissionCompanionInstruction: String {
        if step == 1 {
            return String(
                localized: "computerUse.onboarding.companion.accessibility",
                defaultValue: "Drag \(runtimeService.applicationName) to the list above to allow Accessibility"
            )
        }
        return String(
            localized: "computerUse.onboarding.companion.screenRecording",
            defaultValue: "Drag \(runtimeService.applicationName) to the list above to allow Screen Recording"
        )
    }

    private var currentPermissionGranted: Bool {
        step == 1 ? accessibilityGranted : screenRecordingGranted
    }

    private func permissionStatus(granted: Bool, label: String? = nil) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(granted ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            if let label {
                Text(label)
            }
            Text(
                granted
                    ? String(localized: "computerUse.onboarding.status.granted", defaultValue: "Granted")
                    : String(localized: "computerUse.onboarding.status.notGranted", defaultValue: "Not Granted")
            )
            .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
    }

    private func refreshPermissions() {
        guard !refreshInFlight else { return }
        refreshInFlight = true
        Task { @MainActor in
            defer { refreshInFlight = false }
            let status = await runtimeService.refreshHelperStatus()
            refreshHelperPresentation()
            applyPermissions(
                accessibilityGranted: status.accessibility,
                screenRecordingGranted: status.screenRecording
            )
        }
    }

    private func handleHelperDragEnded(operation: NSDragOperation) {
        guard operation != [] else { return }
        permissionCheckArmed = true
        refreshPermissions()
    }

    private func prepareHelperForOnboarding() {
        Task { @MainActor in
            _ = await runtimeService.ensureStandaloneHelperInstalled()
            refreshHelperPresentation()
            let status = await runtimeService.refreshHelperStatus()
            accessibilityGranted = status.accessibility
            screenRecordingGranted = status.screenRecording

            guard initialStep > Self.initialStep, !initialPermissionFlowStarted else { return }
            initialPermissionFlowStarted = true

            if initialStep == 1, status.accessibility {
                if status.screenRecording {
                    step = 3
                } else {
                    beginPermissionSetup(for: 2)
                }
            } else if initialStep == 2, status.screenRecording {
                step = 3
            } else {
                beginPermissionSetup(for: initialStep)
            }
        }
    }

    private func beginPermissionSetup(for permissionStep: Int) {
        guard
            permissionStep == 1 || permissionStep == 2,
            !permissionSetupInFlight
        else {
            return
        }
        step = permissionStep
        permissionSetupInFlight = true
        permissionCheckArmed = true
        Task { @MainActor in
            let didOpenSettings = if permissionStep == 1 {
                await runtimeService.requestAccessibility()
            } else {
                await runtimeService.requestScreenRecording()
            }
            permissionSetupInFlight = false
            guard didOpenSettings else {
                permissionCheckArmed = false
                return
            }
            isPermissionCompanionVisible = true
            onSystemSettingsOpened()
        }
    }

    private func refreshHelperPresentation() {
        let url = runtimeService.helperAppURL
        helperAppURL = url
        helperIcon = url.map { NSWorkspace.shared.icon(forFile: $0.path) }
    }

    private func applyPermissions(
        accessibilityGranted newAccessibilityGranted: Bool,
        screenRecordingGranted newScreenRecordingGranted: Bool
    ) {
        accessibilityGranted = newAccessibilityGranted
        screenRecordingGranted = newScreenRecordingGranted

        if step == 1, newAccessibilityGranted {
            if newScreenRecordingGranted {
                step = 3
            } else {
                beginPermissionSetup(for: 2)
            }
        } else if step == 2, newScreenRecordingGranted {
            step = 3
        }
    }
}
