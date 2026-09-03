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

    private var visualTokens: ComputerUseOnboardingVisualTokens {
        ComputerUseOnboardingVisualTokens.reference
    }

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
        .frame(
            width: visualTokens.expandedWindowSize.width,
            height: visualTokens.expandedWindowSize.height
        )
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
                    .padding(.top, visualTokens.expandedHeroTopInset)

                Text(String(
                    localized: "computerUse.onboarding.hero.title",
                    defaultValue: "Enable cmux Computer Use"
                ))
                .font(.system(size: visualTokens.titlePointSize, weight: .bold))
                .lineLimit(2)
                .minimumScaleFactor(visualTokens.titleMinimumScaleFactor)
                .padding(.top, visualTokens.heroTitleSpacing)

                Text(heroDetail)
                    .font(.system(size: visualTokens.bodyPointSize))
                    .foregroundStyle(overviewSecondaryText)
                    .multilineTextAlignment(.center)
                    .lineSpacing(visualTokens.heroDetailLineSpacing)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, visualTokens.heroDetailSpacing)

                permissionOverview
                    .padding(.top, visualTokens.heroPermissionsSpacing)

                Spacer(minLength: visualTokens.expandedFooterMinimumGap)

                Text(String(
                    localized: "computerUse.onboarding.hero.helperNote",
                    defaultValue: "Permissions go to the separate cmux Computer Use helper — the cmux terminal itself never receives them."
                ))
                .font(.system(size: 11))
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, visualTokens.expandedFooterBottomInset)
            }
            .padding(.horizontal, visualTokens.expandedContentHorizontalInset)

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
            .frame(
                width: visualTokens.completionMarkSize,
                height: visualTokens.completionMarkSize
            )
            .padding(.top, visualTokens.completionTopInset)
            .accessibilityHidden(true)

            Text(String(
                localized: "computerUse.onboarding.done.title",
                defaultValue: "cmux Computer Use Is Ready"
            ))
            .font(.system(size: visualTokens.titlePointSize, weight: .bold))
            .lineLimit(2)
            .minimumScaleFactor(visualTokens.titleMinimumScaleFactor)
            .padding(.top, visualTokens.completionTitleSpacing)

            Text(String(
                localized: "computerUse.onboarding.done.detailReady",
                defaultValue: "Setup is complete. You can now ask cmux to use apps on your Mac."
            ))
            .font(.system(size: visualTokens.bodyPointSize))
            .foregroundStyle(overviewSecondaryText)
            .multilineTextAlignment(.center)
            .lineSpacing(visualTokens.heroDetailLineSpacing)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, visualTokens.completionDetailSpacing)

            ProgressView()
                .controlSize(.small)
                .tint(.secondary)
                .padding(.top, visualTokens.completionProgressSpacing)

            Spacer()
        }
        .padding(.horizontal, visualTokens.completionContentHorizontalInset)
    }

    /// The flat cmux brand blue (#2D8CFF) — the midpoint of the cursor
    /// artwork's palette, used as a solid fill. Onboarding chrome stays flat;
    /// gradients live only inside the icon artwork itself.
    static let brandBlue = ComputerUseOnboardingVisualTokens.reference.brandBlue
    /// The flat cmux brand violet (#6C5CFF), the palette's far endpoint.
    static let brandViolet = ComputerUseOnboardingVisualTokens.reference.brandViolet

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
                    RoundedRectangle(
                        cornerRadius: visualTokens.tileCornerRadius(
                            for: visualTokens.heroArtworkSize
                        ),
                        style: .continuous
                    )
                        .fill(Self.brandBlue)
                    Image(systemName: "cursorarrow.motionlines")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(
            width: visualTokens.heroArtworkSize,
            height: visualTokens.heroArtworkSize
        )
        .accessibilityHidden(true)
    }

    private var permissionOverview: some View {
        VStack(spacing: visualTokens.permissionCardRowsSpacing) {
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
        HStack(spacing: visualTokens.permissionCardContentSpacing) {
            permissionIcon(for: permissionStep)

            VStack(alignment: .leading, spacing: visualTokens.permissionCardTextSpacing) {
                Text(title)
                    .font(
                        .system(
                            size: visualTokens.permissionTitlePointSize,
                            weight: .semibold
                        )
                    )
                    .lineLimit(1)
                    .minimumScaleFactor(visualTokens.titleMinimumScaleFactor)
                Text(detail)
                    .font(.system(size: visualTokens.permissionDetailPointSize))
                    .foregroundStyle(overviewSecondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(visualTokens.compactTextMinimumScaleFactor)
                    .allowsTightening(true)
            }
            .layoutPriority(1)

            Spacer(minLength: visualTokens.permissionCardContentSpacing)
            permissionAction(for: permissionStep, granted: granted)
        }
        .padding(.horizontal, visualTokens.permissionCardHorizontalInset)
        .frame(maxWidth: .infinity)
        .frame(height: visualTokens.permissionCardHeight)
        .background(
            permissionCardBackground,
            in: RoundedRectangle(
                cornerRadius: visualTokens.permissionCardCornerRadius,
                style: .continuous
            )
        )
        .overlay {
            RoundedRectangle(
                cornerRadius: visualTokens.permissionCardCornerRadius,
                style: .continuous
            )
                .strokeBorder(permissionCardBorder, lineWidth: 1)
        }
    }

    /// System-Settings-style permission tiles: flat rounded squares in the two
    /// solid brand hues, so the pair reads as one family without any gradient.
    @ViewBuilder
    private func permissionIcon(for permissionStep: ComputerUseOnboardingStep) -> some View {
        ZStack {
            RoundedRectangle(
                cornerRadius: visualTokens.tileCornerRadius(
                    for: visualTokens.permissionCardIconSize
                ),
                style: .continuous
            )
                .fill(
                    permissionStep == .accessibility
                        ? Self.brandBlue
                        : Self.brandViolet
                )
            Image(
                systemName: permissionStep == .accessibility
                    ? "accessibility"
                    : "camera.viewfinder"
            )
            .font(.system(size: 20, weight: .medium))
            .foregroundStyle(.white)
        }
        .frame(
            width: visualTokens.permissionCardIconSize,
            height: visualTokens.permissionCardIconSize
        )
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
                    .font(
                        .system(size: visualTokens.actionPointSize, weight: .semibold)
                    )
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
                .font(
                    .system(size: visualTokens.actionPointSize, weight: .semibold)
                )
                .frame(
                    width: visualTokens.permissionActionSize.width,
                    height: visualTokens.permissionActionSize.height
                )
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
