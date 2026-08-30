import AppKit
import SwiftUI

/// Two-card onboarding for the standalone local computer-use helper.
///
/// Permissions belong to `cmux Computer Use`. Each initial Allow action opens
/// the matching permanent System Settings pane directly and presents the helper
/// as a Finder-compatible drag source when macOS has not listed it yet.
@MainActor
struct ComputerUseOnboardingView: View {
    static let initialStep = ComputerUseOnboardingStep.overview

    let runtimeService: ComputerUseRuntimeService
    @ObservedObject var presentationState: ComputerUseOnboardingPresentationState
    let initialStep: ComputerUseOnboardingStep
    let initialDirectCaptureReady: Bool
    let onPermissionSetupStarted: @MainActor (ComputerUseOnboardingStep) -> Void
    let onPermissionCompanionLayoutReady: @MainActor () -> Void
    let onExpandedRequested: @MainActor () -> Void
    let onOnboardingCompleted: @MainActor () -> Void

    @State private var step: ComputerUseOnboardingStep
    @State private var accessibilityGranted = false
    @State private var screenRecordingGranted = false
    @State private var permissionStatusIsKnown = false
    @State private var refreshInFlight = false
    @State private var permissionChangeRefreshInFlight = false
    @State private var permissionCheckArmed = false
    @State private var helperAppURL: URL?
    @State private var initialPermissionFlowStarted = false
    @State private var permissionSetupInFlight = false
    @State private var directCaptureReady: Bool
    @State private var directCaptureVerificationInFlight = false
    @State private var directCaptureVerificationAttempted = false
    @State private var settingsOpened: Set<ComputerUseSystemPermission> = []

    init(
        runtimeService: ComputerUseRuntimeService,
        presentationState: ComputerUseOnboardingPresentationState,
        initialStep: ComputerUseOnboardingStep = .overview,
        initialDirectCaptureReady: Bool = false,
        onPermissionSetupStarted: @escaping @MainActor (ComputerUseOnboardingStep) -> Void = { _ in },
        onPermissionCompanionLayoutReady: @escaping @MainActor () -> Void = {},
        onExpandedRequested: @escaping @MainActor () -> Void = {},
        onOnboardingCompleted: @escaping @MainActor () -> Void = {}
    ) {
        self.runtimeService = runtimeService
        self.presentationState = presentationState
        self.initialStep = initialStep
        self.initialDirectCaptureReady = initialDirectCaptureReady
        self.onPermissionSetupStarted = onPermissionSetupStarted
        self.onPermissionCompanionLayoutReady = onPermissionCompanionLayoutReady
        self.onExpandedRequested = onExpandedRequested
        self.onOnboardingCompleted = onOnboardingCompleted
        _step = State(initialValue: initialStep)
        _directCaptureReady = State(initialValue: initialDirectCaptureReady)
    }

    private var isPermissionCompanionVisible: Bool {
        presentationState.permissionCompanionVisible
    }

    @Environment(\.colorScheme) private var colorScheme

    private var helperIcon: NSImage? {
        ComputerUseHelperIconRenderer.image(darkMode: colorScheme == .dark)
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
        .ignoresSafeArea()
        .background {
            if !isPermissionCompanionVisible {
                onboardingBackground
            }
        }
        .onAppear {
            prepareHelperForOnboarding()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard permissionCheckArmed else { return }
            permissionCheckArmed = false
            refreshPermissions()
        }
        .onChange(of: presentationState.returnToOverviewGeneration) {
            step = .overview
            refreshPermissions()
        }
        .onChange(of: presentationState.permissionSnapshot) {
            guard let snapshot = presentationState.permissionSnapshot else {
                return
            }
            refreshHelperPresentation()
            applyPermissions(
                statusIsKnown: snapshot.statusIsKnown,
                accessibilityGranted: snapshot.accessibilityGranted,
                screenRecordingGranted: snapshot.screenRecordingGranted
            )
        }
        .task {
            await refreshPermissionsNow()
            for await _ in runtimeService.permissionStatusEvents() {
                guard !Task.isCancelled else { return }
                await refreshPermissionsNow()
            }
        }
    }

    private var onboardingBackground: some View {
        Color(nsColor: .windowBackgroundColor)
    }

    private var overviewSecondaryText: Color {
        Color(nsColor: .secondaryLabelColor)
    }

    private var permissionCardBackground: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.055)
            : Color(nsColor: .controlBackgroundColor)
    }

    private var permissionCardBorder: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.09)
            : Color(nsColor: .separatorColor).opacity(0.55)
    }

    /// The reference-style overview shown before entering a macOS permission pane.
    private var expandedOnboarding: some View {
        Group {
            if step == .complete {
                completedOnboarding
            } else {
                permissionOnboarding
            }
        }
        .frame(width: 600, height: 440)
    }

    /// While the direct-capture probe is up, the system shows its "requesting
    /// to bypass the system private window picker" alert — the hero line must
    /// explain that alert instead of restating the two permissions.
    private var heroDetail: String {
        if directCaptureVerificationInFlight {
            return String(
                localized: "computerUse.onboarding.hero.confirmCapture",
                defaultValue: "macOS is asking to confirm screen capture.\nChoose Allow in the system alert to finish setup."
            )
        }
        return String(
            localized: "computerUse.onboarding.hero.detail",
            defaultValue: "cmux Computer Use needs these permissions to use apps on your Mac.\nThese permissions are used when you ask cmux to perform tasks."
        )
    }

    private var permissionOnboarding: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                helperHeroIcon
                    .padding(.top, 46)

                Text(String(
                    localized: "computerUse.onboarding.hero.title",
                    defaultValue: "Enable cmux Computer Use"
                ))
                .font(.system(size: 25, weight: .bold))
                .padding(.top, 18)

                Text(heroDetail)
                .font(.system(size: 13))
                .foregroundStyle(overviewSecondaryText)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 9)

                permissionOverview
                    .padding(.top, 22)

                Spacer(minLength: 12)

                Text(String(
                    localized: "computerUse.onboarding.hero.helperNote",
                    defaultValue: "Permissions go to the separate cmux Computer Use helper — the cmux terminal itself never receives them."
                ))
                .font(.system(size: 11))
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 18)
            }
            .padding(.horizontal, 40)

            ComputerUseWindowDragRegion()
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .accessibilityHidden(true)
        }
    }

    private var completedOnboarding: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(Color.green)
                Image(systemName: "checkmark")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 60, height: 60)
            .padding(.top, 108)
            .accessibilityHidden(true)

            Text(String(
                localized: "computerUse.onboarding.done.title",
                defaultValue: "cmux Computer Use Is Ready"
            ))
            .font(.system(size: 25, weight: .bold))
            .padding(.top, 20)

            Text(String(
                localized: "computerUse.onboarding.done.detailReady",
                defaultValue: "Setup is complete. You can now ask cmux to use apps on your Mac."
            ))
            .font(.system(size: 13))
            .foregroundStyle(overviewSecondaryText)
            .multilineTextAlignment(.center)
            .lineSpacing(3)
            .padding(.top, 9)

            ProgressView()
                .controlSize(.small)
                .tint(.secondary)
                .padding(.top, 28)

            Spacer()
        }
        .padding(.horizontal, 48)
    }

    /// The flat cmux brand blue (#2D8CFF) — the midpoint of the cursor
    /// artwork's palette, used as a solid fill. Onboarding chrome stays flat;
    /// gradients live only inside the icon artwork itself.
    static let brandBlue = Color(red: 0x2D / 255.0, green: 0x8C / 255.0, blue: 0xFF / 255.0)
    /// The flat cmux brand violet (#6C5CFF), the palette's far endpoint.
    static let brandViolet = Color(red: 0x6C / 255.0, green: 0x5C / 255.0, blue: 0xFF / 255.0)

    private var helperHeroIcon: some View {
        Group {
            if let helperIcon {
                // The renderer draws the tile full-bleed with its own rim, so
                // the artwork needs no scale compensation or extra border.
                Image(nsImage: helperIcon)
                    .resizable()
                    .interpolation(.high)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Self.brandBlue)
                    Image(systemName: "cursorarrow.motionlines")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: 64, height: 64)
        .accessibilityHidden(true)
    }

    private var permissionOverview: some View {
        VStack(spacing: 12) {
            permissionCard(
                permissionStep: .accessibility,
                granted: accessibilityGranted,
                title: String(
                    localized: "computerUse.onboarding.accessibility.short",
                    defaultValue: "Accessibility"
                ),
                detail: String(
                    localized: "computerUse.onboarding.accessibility.cardDetail",
                    defaultValue: "Allows cmux to access app interfaces"
                )
            )
            permissionCard(
                permissionStep: .screenRecording,
                granted: screenRecordingGranted && directCaptureReady,
                title: String(
                    localized: "computerUse.onboarding.screenshots.short",
                    defaultValue: "Screenshots"
                ),
                detail: screenshotsCardDetail
            )
        }
    }

    /// Once ordinary Screen Recording is on, the remaining blocker is Tahoe's
    /// direct-capture consent alert — say so instead of re-explaining
    /// screenshots while a scary system dialog is (or is about to be) up.
    private var screenshotsCardDetail: String {
        if permissionStatusIsKnown, screenRecordingGranted, !directCaptureReady {
            return String(
                localized: "computerUse.onboarding.screenshots.confirmDetail",
                defaultValue: "macOS asks to confirm — allow screen capture"
            )
        }
        return String(
            localized: "computerUse.onboarding.screenshots.cardDetail",
            defaultValue: "cmux uses screenshots to know where to click"
        )
    }

    private func permissionCard(
        permissionStep: ComputerUseOnboardingStep,
        granted: Bool,
        title: String,
        detail: String
    ) -> some View {
        HStack(spacing: 14) {
            permissionIcon(for: permissionStep)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12.5))
                    .foregroundStyle(overviewSecondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)
            permissionAction(for: permissionStep, granted: granted)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .frame(height: 72)
        .background(
            permissionCardBackground,
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(permissionCardBorder, lineWidth: 1)
        }
    }

    /// System-Settings-style permission tiles: flat rounded squares in the two
    /// solid brand hues, so the pair reads as one family without any gradient.
    @ViewBuilder
    private func permissionIcon(for permissionStep: ComputerUseOnboardingStep) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(permissionStep == .accessibility ? Self.brandBlue : Self.brandViolet)
            Image(
                systemName: permissionStep == .accessibility
                    ? "accessibility"
                    : "camera.viewfinder"
            )
            .font(.system(size: 20, weight: .medium))
            .foregroundStyle(.white)
        }
        .frame(width: 38, height: 38)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func permissionAction(
        for permissionStep: ComputerUseOnboardingStep,
        granted: Bool
    ) -> some View {
        let systemPermission = systemPermission(for: permissionStep)
        let action = ComputerUsePermissionRowAction.resolve(
            granted: granted,
            statusIsKnown: permissionStatusIsKnown,
            systemSettingsOpened: systemPermission.map {
                settingsOpened.contains($0)
            } ?? false
        )
        if action == .done {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.green)
                Text(String(localized: "computerUse.onboarding.done", defaultValue: "Done"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        } else {
            let isButtonEnabled = ComputerUsePermissionRowAction.isButtonEnabled(
                helperIsReady: helperAppURL != nil,
                permissionSetupInFlight: permissionSetupInFlight
                    || directCaptureVerificationInFlight
            )
            Button {
                performAllowAction(for: permissionStep)
            } label: {
                Text(String(
                    localized: "computerUse.onboarding.allow",
                    defaultValue: "Allow"
                ))
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 62, height: 26)
                .foregroundStyle(.white)
                .background(Self.brandBlue, in: Capsule())
                .opacity(isButtonEnabled ? 1 : 0.5)
            }
            .buttonStyle(.plain)
            .disabled(!isButtonEnabled)
            .accessibilityHint(
                permissionAllowAccessibilityHint(for: permissionStep)
            )
        }
    }

    private var permissionCompanion: some View {
        ComputerUsePermissionCompanionView(
            permissionStep: step,
            presentationState: presentationState,
            applicationName: runtimeService.applicationName,
            helperAppURL: helperAppURL,
            onBack: {
                onExpandedRequested()
                refreshPermissions()
            },
            onDragEnded: handleHelperDragEnded,
            onLayoutReady: {
                if presentationState.markPermissionCompanionLayoutReady() {
                    onPermissionCompanionLayoutReady()
                }
            }
        )
    }

    private func refreshPermissions() {
        Task { @MainActor in
            await refreshPermissionsNow()
        }
    }

    private func refreshPermissionsNow() async {
        guard !refreshInFlight else { return }
        refreshInFlight = true
        defer { refreshInFlight = false }
        let status = await runtimeService.refreshHelperStatus()
        guard !Task.isCancelled else { return }
        refreshHelperPresentation()
        applyPermissions(
            statusIsKnown: runtimeService.permissionStatusIsKnown,
            accessibilityGranted: status.accessibility,
            screenRecordingGranted: status.screenRecording
        )
    }

    private func handleHelperDragEnded(operation: NSDragOperation) {
        guard operation != [] else { return }
        permissionCheckArmed = true
        Task { @MainActor in
            await refreshPermissionsAfterPermissionChange()
        }
    }

    private func refreshPermissionsAfterPermissionChange() async {
        guard !permissionChangeRefreshInFlight else { return }
        permissionChangeRefreshInFlight = true
        defer { permissionChangeRefreshInFlight = false }
        let status = await runtimeService
            .refreshHelperStatusAfterPermissionChange()
        guard !Task.isCancelled else { return }
        refreshHelperPresentation()
        applyPermissions(
            statusIsKnown: runtimeService.permissionStatusIsKnown,
            accessibilityGranted: status.accessibility,
            screenRecordingGranted: status.screenRecording
        )
    }

    private func prepareHelperForOnboarding() {
        Task { @MainActor in
            _ = await runtimeService.ensureStandaloneHelperInstalled()
            refreshHelperPresentation()
            let status = await runtimeService.refreshHelperStatus()
            permissionStatusIsKnown = runtimeService.permissionStatusIsKnown
            accessibilityGranted = status.accessibility
            screenRecordingGranted = status.screenRecording

            guard initialStep != Self.initialStep, !initialPermissionFlowStarted else { return }
            initialPermissionFlowStarted = true

            if initialStep == .accessibility, !status.accessibility {
                beginPermissionSetup(for: .accessibility)
            } else if initialStep == .screenRecording, !status.screenRecording {
                beginPermissionSetup(for: initialStep)
            }
        }
    }

    private func beginPermissionSetup(for permissionStep: ComputerUseOnboardingStep) {
        guard
            permissionStep == .accessibility || permissionStep == .screenRecording,
            !permissionSetupInFlight
        else {
            return
        }

        let granted = permissionStep == .accessibility
            ? accessibilityGranted
            : screenRecordingGranted
        guard !permissionStatusIsKnown || !granted else { return }

        step = permissionStep
        permissionSetupInFlight = true
        permissionCheckArmed = true
        onPermissionSetupStarted(permissionStep)
        Task { @MainActor in
            defer { permissionSetupInFlight = false }
            _ = await runtimeService.ensureStandaloneHelperInstalled()
            let status = await runtimeService.refreshHelperStatus()
            guard !Task.isCancelled else { return }
            refreshHelperPresentation()
            applyPermissions(
                statusIsKnown: runtimeService.permissionStatusIsKnown,
                accessibilityGranted: status.accessibility,
                screenRecordingGranted: status.screenRecording
            )
            guard
                !Task.isCancelled,
                let systemPermission = systemPermission(for: permissionStep)
            else {
                return
            }

            // Helper installation and status refresh both suspend. Re-read the
            // permission after that boundary because a grant can arrive while
            // setup is in flight (for example after Quit & Reopen).
            let currentlyGranted = permissionStep == .accessibility
                ? accessibilityGranted
                : screenRecordingGranted
            guard !permissionStatusIsKnown || !currentlyGranted else { return }
            let action = ComputerUsePermissionRowAction.resolve(
                granted: currentlyGranted,
                statusIsKnown: permissionStatusIsKnown,
                systemSettingsOpened: settingsOpened.contains(
                    systemPermission
                )
            )
            guard action.destination == .systemSettings else { return }
            settingsOpened.insert(systemPermission)
            await openSystemSettings(for: permissionStep)
        }
    }

    private func performAllowAction(for permissionStep: ComputerUseOnboardingStep) {
        switch ComputerUseOnboardingAllowAction.resolve(
            permissionStep: permissionStep,
            statusIsKnown: permissionStatusIsKnown,
            screenRecordingGranted: screenRecordingGranted,
            directCaptureReady: directCaptureReady
        ) {
        case .openSystemSettings:
            beginPermissionSetup(for: permissionStep)
        case .verifyScreenCapture:
            beginDirectCaptureVerification()
        case .none:
            break
        }
    }

    private func permissionAllowAccessibilityHint(
        for permissionStep: ComputerUseOnboardingStep
    ) -> String {
        let action = ComputerUseOnboardingAllowAction.resolve(
            permissionStep: permissionStep,
            statusIsKnown: permissionStatusIsKnown,
            screenRecordingGranted: screenRecordingGranted,
            directCaptureReady: directCaptureReady
        )
        if action == .verifyScreenCapture {
            return String(
                localized: "computerUse.onboarding.finishScreenshotAccess",
                defaultValue: "Finish screenshot access"
            )
        }
        return String(
            localized: "computerUse.onboarding.openSystemSettings",
            defaultValue: "Open System Settings"
        )
    }

    private func openSystemSettings(
        for permissionStep: ComputerUseOnboardingStep
    ) async {
        step = permissionStep
        permissionCheckArmed = true
        if permissionStep == .accessibility {
            _ = await runtimeService.openAccessibilitySettings()
        } else {
            _ = await runtimeService.openScreenRecordingSettings()
        }
    }

    private func systemPermission(
        for permissionStep: ComputerUseOnboardingStep
    ) -> ComputerUseSystemPermission? {
        switch permissionStep {
        case .accessibility:
            .accessibility
        case .screenRecording:
            .screenRecording
        case .overview:
            nil
        case .complete:
            nil
        }
    }

    private func refreshHelperPresentation() {
        let url = runtimeService.helperAppURL
        helperAppURL = url
    }

    private func applyPermissions(
        statusIsKnown: Bool,
        accessibilityGranted newAccessibilityGranted: Bool,
        screenRecordingGranted newScreenRecordingGranted: Bool
    ) {
        permissionStatusIsKnown = statusIsKnown
        accessibilityGranted = newAccessibilityGranted
        screenRecordingGranted = newScreenRecordingGranted
        if !newScreenRecordingGranted {
            directCaptureReady = false
            directCaptureVerificationAttempted = false
        }

        switch ComputerUseOnboardingAdvance.resolve(
            activeStep: step,
            statusIsKnown: statusIsKnown,
            accessibilityGranted: newAccessibilityGranted,
            screenRecordingGranted: newScreenRecordingGranted,
            directCaptureReady: directCaptureReady
        ) {
        case .none:
            break
        case .requestSecondAllow:
            step = .screenRecording
            onExpandedRequested()
        case .verifyScreenCapture:
            if !directCaptureVerificationAttempted {
                beginDirectCaptureVerification()
            }
        case .complete:
            if step != .complete {
                step = .complete
                onOnboardingCompleted()
            }
        }
    }

    private func beginDirectCaptureVerification() {
        guard !directCaptureVerificationInFlight else { return }
        directCaptureVerificationAttempted = true
        directCaptureVerificationInFlight = true
        // The probe can raise Tahoe's system consent alert. Flag it so the
        // visible presentation explains the alert instead of surprising the
        // user with "attempting to bypass" wording out of nowhere.
        presentationState.beginScreenCaptureConsent()
        // Leave the compact System Settings companion immediately. The direct
        // capture prompt belongs to the final onboarding phase, and keeping the
        // drag tile up made a successful second drag look stuck while the
        // helper recovered and macOS prepared its consent alert.
        onExpandedRequested()
        Task { @MainActor in
            let verification = await runtimeService
                .verifyDirectScreenCaptureOutcome()
            // Completion is forbidden while this flag is set. Clear the
            // prompt-capable phase before applying the successful result so
            // the controller can atomically replace the companion with Done.
            directCaptureVerificationInFlight = false
            presentationState.endScreenCaptureConsent()
            guard !Task.isCancelled else { return }
            directCaptureReady = verification == .ready
            if verification == .ready {
                applyPermissions(
                    statusIsKnown: permissionStatusIsKnown,
                    accessibilityGranted: accessibilityGranted,
                    screenRecordingGranted: screenRecordingGranted
                )
            } else {
                if verification == .unavailable {
                    // A helper replacement is not a user denial. Permit a later
                    // TCC/status event or explicit Allow action to retry instead
                    // of leaving this onboarding run permanently attempted.
                    directCaptureVerificationAttempted = false
                }
                step = .screenRecording
                onExpandedRequested()
            }
        }
    }
}

enum ComputerUsePermissionCompanionLayout {
    static let size = CGSize(width: 472, height: 112)
    static let horizontalInset: CGFloat = 12
    static let verticalInset: CGFloat = 8
    static let leadingColumnWidth: CGFloat = 40
    static let headerHeight: CGFloat = 48
    static let dragRowHeight: CGFloat = 40
    static let columnSpacing: CGFloat = 8
    static let rowSpacing: CGFloat = 8
}

/// The borderless drag surface shown beside System Settings.
///
/// Both rows use the same fixed leading column and inter-column spacing, so
/// the instruction text and app tile share an exact leading edge.
@MainActor
struct ComputerUsePermissionCompanionView: View {
    let permissionStep: ComputerUseOnboardingStep
    @ObservedObject var presentationState: ComputerUseOnboardingPresentationState
    let applicationName: String
    let helperAppURL: URL?
    let onBack: @MainActor () -> Void
    let onDragEnded: @MainActor (NSDragOperation) -> Void
    let onLayoutReady: @MainActor () -> Void

    private var message: ComputerUsePermissionCompanionMessage {
        ComputerUsePermissionCompanionMessage.resolve(
            permissionStep: permissionStep,
            screenCaptureConsentPending: presentationState.screenCaptureConsentPending
        )
    }

    @Environment(\.colorScheme) private var colorScheme

    private var helperIcon: NSImage? {
        ComputerUseHelperIconRenderer.image(darkMode: colorScheme == .dark)
    }

    var body: some View {
        VStack(spacing: ComputerUsePermissionCompanionLayout.rowSpacing) {
            HStack(spacing: ComputerUsePermissionCompanionLayout.columnSpacing) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(ComputerUseOnboardingView.brandBlue)
                    .frame(width: 30, height: 30)
                    .background(
                        Color.accentColor.opacity(0.12),
                        in: Circle()
                    )
                    .frame(
                        width: ComputerUsePermissionCompanionLayout.leadingColumnWidth,
                        height: ComputerUsePermissionCompanionLayout.headerHeight
                    )
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 1) {
                    Text(instruction)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.88)

                    Text(followUp)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(
                    maxWidth: .infinity,
                    minHeight: ComputerUsePermissionCompanionLayout.headerHeight,
                    maxHeight: ComputerUsePermissionCompanionLayout.headerHeight,
                    alignment: .leading
                )
                .accessibilityElement(children: .combine)
            }

            HStack(spacing: ComputerUsePermissionCompanionLayout.columnSpacing) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary.opacity(0.72))
                .frame(
                    width: ComputerUsePermissionCompanionLayout.leadingColumnWidth,
                    height: ComputerUsePermissionCompanionLayout.dragRowHeight
                )
                .background(
                    Color.primary.opacity(0.055),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(
                            Color(nsColor: .separatorColor).opacity(0.32),
                            lineWidth: 0.5
                        )
                }
                .help(String(localized: "computerUse.onboarding.back", defaultValue: "Back"))
                .accessibilityLabel(
                    String(localized: "computerUse.onboarding.back", defaultValue: "Back")
                )

                helperDragTile
            }
        }
        .padding(.horizontal, ComputerUsePermissionCompanionLayout.horizontalInset)
        .padding(.vertical, ComputerUsePermissionCompanionLayout.verticalInset)
        .frame(
            width: ComputerUsePermissionCompanionLayout.size.width,
            height: ComputerUsePermissionCompanionLayout.size.height
        )
        .background(
            Color(nsColor: .windowBackgroundColor),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    Color(nsColor: .separatorColor).opacity(0.5),
                    lineWidth: 0.5
                )
        }
        .onAppear(perform: onLayoutReady)
    }

    /// A file-URL drag source accepted by the macOS permission lists.
    private var helperDragTile: some View {
        HStack(spacing: 10) {
            Group {
                if let helperIcon {
                    Image(nsImage: helperIcon)
                        .resizable()
                        .interpolation(.high)
                } else {
                    Image(systemName: "app.dashed")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 26, height: 26)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(
                        Color(nsColor: .separatorColor).opacity(0.35),
                        lineWidth: 0.5
                    )
            }
            .accessibilityHidden(true)

            Text(applicationName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 10)
        }
        .padding(.horizontal, 11)
        .frame(
            maxWidth: .infinity,
            minHeight: ComputerUsePermissionCompanionLayout.dragRowHeight,
            maxHeight: ComputerUsePermissionCompanionLayout.dragRowHeight,
            alignment: .leading
        )
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.055))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.accentColor.opacity(0.035))
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    Color.accentColor.opacity(0.18),
                    lineWidth: 0.5
                )
        }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            ComputerUseAppDragSource(
                helperAppURL: helperAppURL,
                helperIcon: helperIcon,
                onDragEnded: onDragEnded
            )
            .accessibilityHidden(true)
            .allowsHitTesting(helperAppURL != nil)
        }
        .help(String(
            localized: "computerUse.onboarding.dragTooltip",
            defaultValue: "Drag \(applicationName) into the permission list"
        ))
        .opacity(helperAppURL == nil ? 0.55 : 1)
    }

    private var instruction: String {
        switch message {
        case .dragIntoAccessibility:
            String(
                localized: "computerUse.onboarding.companion.accessibility",
                defaultValue: "Drag \(applicationName) into Accessibility"
            )
        case .dragIntoScreenshots:
            String(
                localized: "computerUse.onboarding.companion.screenRecording",
                defaultValue: "Drag \(applicationName) into Screenshots"
            )
        case .confirmScreenCapture:
            String(
                localized: "computerUse.onboarding.companion.confirmCapture",
                defaultValue: "Allow screen capture in the macOS alert"
            )
        }
    }

    private var followUp: String {
        switch message {
        case .dragIntoAccessibility, .dragIntoScreenshots:
            String(
                localized: "computerUse.onboarding.companion.turnOn",
                defaultValue: "Then turn it on."
            )
        case .confirmScreenCapture:
            String(
                localized: "computerUse.onboarding.companion.confirmCapture.detail",
                defaultValue: "The system “bypass” warning is expected here."
            )
        }
    }
}
