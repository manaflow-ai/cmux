import AppKit
import SwiftUI

/// Non-blocking three-step introduction and permission checklist for local computer use.
@MainActor
struct ComputerUseOnboardingView: View {
    let permissionService: ComputerUsePermissionService
    let agentSessionRequiresRestart: @MainActor () -> Bool
    let onClose: () -> Void

    @State private var step = 0
    @State private var accessibilityGranted = false
    @State private var screenRecordingGranted = false
    @State private var restartRequired = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(28)
            Divider()
            footer
        }
        .frame(width: 620, height: 440)
        .onAppear(perform: refreshPermissions)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            refreshPermissions()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "cursorarrow.rays")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "computerUse.onboarding.title", defaultValue: "Computer Use"))
                    .font(.title2.weight(.semibold))
                if step < 3 {
                    Text(String(localized: "computerUse.onboarding.step", defaultValue: "Step \(step + 1) of 3"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if step < 3 {
                Button(String(localized: "computerUse.onboarding.notNow", defaultValue: "Not Now"), action: onClose)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case 0:
            overview
        case 1:
            permissionStep(
                symbolName: "accessibility",
                title: String(localized: "computerUse.onboarding.accessibility.title", defaultValue: "Grant Accessibility"),
                detail: String(localized: "computerUse.onboarding.accessibility.detail", defaultValue: "Accessibility lets the local driver inspect controls, click buttons, and type in apps you ask an agent to use."),
                granted: accessibilityGranted,
                grant: {
                    permissionService.requestAccessibility()
                    refreshPermissions()
                },
                openSettings: permissionService.openAccessibilitySettings
            )
        case 2:
            permissionStep(
                symbolName: "rectangle.inset.filled.and.person.filled",
                title: String(localized: "computerUse.onboarding.screenRecording.title", defaultValue: "Grant Screen Recording"),
                detail: String(localized: "computerUse.onboarding.screenRecording.detail", defaultValue: "Screen Recording lets the local driver see app windows and screen content so it can act on what is visible."),
                granted: screenRecordingGranted,
                grant: {
                    permissionService.requestScreenRecording()
                    refreshPermissions()
                },
                openSettings: permissionService.openScreenRecordingSettings
            )
        default:
            done
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(String(localized: "computerUse.onboarding.overview.title", defaultValue: "Agents can work across apps on this Mac"))
                .font(.title3.weight(.semibold))
            Text(String(localized: "computerUse.onboarding.overview.detail", defaultValue: "Supported agent sessions can see and drive local apps when a task needs more than the terminal. You stay in control and can follow activity from the Computer Use menu-bar item."))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Label(
                String(localized: "computerUse.onboarding.overview.local", defaultValue: "Driven locally under cmux's macOS permissions"),
                systemImage: "macbook"
            )
            Label(
                String(localized: "computerUse.onboarding.overview.telemetry", defaultValue: "Driver telemetry and update checks are disabled"),
                systemImage: "hand.raised"
            )
        }
    }

    private func permissionStep(
        symbolName: String,
        title: String,
        detail: String,
        granted: Bool,
        grant: @escaping () -> Void,
        openSettings: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: symbolName)
                .font(.system(size: 38, weight: .medium))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(title)
                .font(.title3.weight(.semibold))
            Text(detail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            permissionStatus(granted: granted)
            HStack(spacing: 10) {
                Button(String(localized: "computerUse.onboarding.grant", defaultValue: "Grant…"), action: grant)
                    .buttonStyle(.borderedProminent)
                    .disabled(granted)
                Button(String(localized: "computerUse.onboarding.openSystemSettings", defaultValue: "Open System Settings"), action: openSettings)
            }
        }
    }

    private var done: some View {
        let ready = accessibilityGranted && screenRecordingGranted && !restartRequired
        return VStack(alignment: .leading, spacing: 18) {
            Image(systemName: ready ? "checkmark.circle.fill" : (restartRequired ? "arrow.clockwise.circle.fill" : "checklist"))
                .font(.system(size: 42, weight: .medium))
                .foregroundStyle(ready ? Color.green : Color.accentColor)
                .accessibilityHidden(true)
            Text(
                restartRequired
                    ? String(localized: "computerUse.onboarding.done.titleRestartRequired", defaultValue: "Restart the Agent Session")
                    : String(localized: "computerUse.onboarding.done.title", defaultValue: "Computer Use Is Ready")
            )
                .font(.title3.weight(.semibold))
            Text(
                restartRequired
                    ? String(localized: "computerUse.onboarding.done.detailRestartRequired", defaultValue: "The running agent session started before these permissions were granted. Restart that agent session so its computer-use driver picks up the new permission.")
                    : accessibilityGranted && screenRecordingGranted
                    ? String(localized: "computerUse.onboarding.done.detailReady", defaultValue: "Both permissions are granted. Supported agent sessions can now use local computer-use tools.")
                    : String(localized: "computerUse.onboarding.done.detailIncomplete", defaultValue: "You can finish now and grant any missing permission later from Computer Use settings.")
            )
            .foregroundStyle(.secondary)
            permissionStatus(granted: accessibilityGranted, label: String(localized: "computerUse.onboarding.accessibility.short", defaultValue: "Accessibility"))
            permissionStatus(granted: screenRecordingGranted, label: String(localized: "computerUse.onboarding.screenRecording.short", defaultValue: "Screen Recording"))
        }
    }

    private var footer: some View {
        HStack {
            if step > 0 && step < 3 {
                Button(String(localized: "computerUse.onboarding.back", defaultValue: "Back")) {
                    step -= 1
                }
            }
            Spacer()
            if step < 3 {
                Button(String(localized: "computerUse.onboarding.continue", defaultValue: "Continue")) {
                    step += 1
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button(String(localized: "computerUse.onboarding.done", defaultValue: "Done"), action: onClose)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    private func permissionStatus(granted: Bool, label: String? = nil) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(granted ? Color.green : Color.orange)
                .frame(width: 9, height: 9)
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
    }

    private func refreshPermissions() {
        let newAccessibilityGranted = permissionService.accessibilityGranted()
        let newScreenRecordingGranted = permissionService.screenRecordingGranted()
        // Derive directly each refresh rather than gating on a false->true
        // transition observed in this window instance: a fresh onboarding window
        // opened AFTER permissions were granted externally must still surface the
        // restart guidance when a driver session predates the grant. Latched so it
        // stays shown for the rest of this presentation.
        if agentSessionRequiresRestart(), newAccessibilityGranted, newScreenRecordingGranted {
            restartRequired = true
        }
        accessibilityGranted = newAccessibilityGranted
        screenRecordingGranted = newScreenRecordingGranted
    }
}
