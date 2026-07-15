import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Non-blocking, one-permission-at-a-time onboarding for local computer use.
///
/// Permissions are granted to the bundled `cmux Computer Use` helper app (its own
/// bundle id / TCC identity), so each step drives the user straight to the right
/// System Settings pane and offers a drag-and-drop tile of the helper app to drop
/// into the permission list. The flow auto-advances the moment a grant lands.
@MainActor
struct ComputerUseOnboardingView: View {
    let permissionService: ComputerUsePermissionService
    let agentSessionRequiresRestart: @MainActor () -> Bool
    /// Restarts just the computer-use helper (not cmux) so newly granted
    /// permissions take effect. No-op default keeps previews / tests simple.
    var restartHelper: @MainActor () -> Void = {}
    let onClose: () -> Void

    @State private var step = 0
    @State private var accessibilityGranted = false
    @State private var screenRecordingGranted = false
    @State private var restartRequired = false

    private var helperName: String { ComputerUsePermissionService.helperAppName }

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
        .frame(width: 640, height: 470)
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
                Text(String(localized: "computerUse.onboarding.title", defaultValue: "\(ComputerUsePermissionService.helperAppName) Setup"))
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
                detail: String(localized: "computerUse.onboarding.accessibility.detail", defaultValue: "Accessibility lets the computer-use helper inspect controls, click buttons, and type in apps you ask an agent to use."),
                granted: accessibilityGranted,
                grant: {
                    permissionService.requestAccessibility()
                    permissionService.openAccessibilitySettings()
                    refreshPermissions()
                },
                openSettings: permissionService.openAccessibilitySettings
            )
        case 2:
            permissionStep(
                symbolName: "rectangle.inset.filled.and.person.filled",
                title: String(localized: "computerUse.onboarding.screenRecording.title", defaultValue: "Grant Screen Recording"),
                detail: String(localized: "computerUse.onboarding.screenRecording.detail", defaultValue: "Screen Recording lets the computer-use helper see app windows and screen content so it can act on what is visible."),
                granted: screenRecordingGranted,
                grant: {
                    permissionService.requestScreenRecording()
                    permissionService.openScreenRecordingSettings()
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
            Text(String(localized: "computerUse.onboarding.overview.detail", defaultValue: "Supported agent sessions can see and drive local apps when a task needs more than the terminal. Permissions are granted to a separate \(ComputerUsePermissionService.helperAppName) helper, so you never have to restart cmux to enable them."))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Label(
                String(localized: "computerUse.onboarding.overview.separateApp", defaultValue: "Runs as a separate \(ComputerUsePermissionService.helperAppName) helper with its own permissions"),
                systemImage: "square.on.square"
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
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: symbolName)
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.title3.weight(.semibold))
            }
            Text(detail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if granted {
                permissionStatus(granted: true)
            } else {
                if permissionService.helperAppURL != nil {
                    helperDragTile
                }
                HStack(spacing: 10) {
                    Button(String(localized: "computerUse.onboarding.openSystemSettings", defaultValue: "Open System Settings"), action: openSettings)
                        .buttonStyle(.borderedProminent)
                    Button(String(localized: "computerUse.onboarding.grant", defaultValue: "Prompt & Open Settings"), action: grant)
                    if permissionService.helperAppURL != nil {
                        Button(String(localized: "computerUse.onboarding.reveal", defaultValue: "Reveal Helper in Finder")) {
                            permissionService.revealHelperInFinder()
                        }
                    }
                }
                permissionStatus(granted: false)
            }
        }
    }

    /// A draggable tile of the helper app: the user drags it directly into the
    /// System Settings permission list (which accepts a dropped .app to add it).
    private var helperDragTile: some View {
        let url = permissionService.helperAppURL
        let icon = url.map { NSWorkspace.shared.icon(forFile: $0.path) }
        return HStack(spacing: 12) {
            Group {
                if let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 44, height: 44)
                } else {
                    Image(systemName: "app.dashed")
                        .font(.system(size: 34))
                        .frame(width: 44, height: 44)
                }
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(helperName)
                    .font(.body.weight(.medium))
                Text(String(localized: "computerUse.onboarding.dragHint", defaultValue: "Drag this into the list in System Settings, then turn it on."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "arrow.up.forward.app")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.25)))
        .onDrag {
            guard let url else { return NSItemProvider() }
            return NSItemProvider(contentsOf: url) ?? NSItemProvider()
        }
        .help(String(localized: "computerUse.onboarding.dragTooltip", defaultValue: "Drag \(ComputerUsePermissionService.helperAppName) into the permission list"))
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
                    ? String(localized: "computerUse.onboarding.done.titleRestartRequired", defaultValue: "Restart the Helper")
                    : String(localized: "computerUse.onboarding.done.title", defaultValue: "Computer Use Is Ready")
            )
                .font(.title3.weight(.semibold))
            Text(
                restartRequired
                    ? String(localized: "computerUse.onboarding.done.detailRestartRequired", defaultValue: "The \(ComputerUsePermissionService.helperAppName) helper started before these permissions were granted. Restart the helper (not cmux) so it picks up the new permissions.")
                    : accessibilityGranted && screenRecordingGranted
                    ? String(localized: "computerUse.onboarding.done.detailReady", defaultValue: "Both permissions are granted. Supported agent sessions can now use local computer-use tools.")
                    : String(localized: "computerUse.onboarding.done.detailIncomplete", defaultValue: "You can finish now and grant any missing permission later from Computer Use settings.")
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            permissionStatus(granted: accessibilityGranted, label: String(localized: "computerUse.onboarding.accessibility.short", defaultValue: "Accessibility"))
            permissionStatus(granted: screenRecordingGranted, label: String(localized: "computerUse.onboarding.screenRecording.short", defaultValue: "Screen Recording"))
            if restartRequired {
                Button(String(localized: "computerUse.onboarding.restartHelper", defaultValue: "Restart Helper")) {
                    restartHelper()
                    restartRequired = false
                }
                .buttonStyle(.borderedProminent)
            }
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
        // The helper (not cmux) owns the grants, so query its own TCC identity
        // out of process, then apply the result on the main actor.
        Task {
            let status = await permissionService.refreshHelperStatus()
            applyPermissions(
                accessibilityGranted: status.accessibility,
                screenRecordingGranted: status.screenRecording
            )
        }
    }

    private func applyPermissions(
        accessibilityGranted newAccessibilityGranted: Bool,
        screenRecordingGranted newScreenRecordingGranted: Bool
    ) {
        // Derive directly each refresh rather than gating on a false->true
        // transition observed in this window instance: a fresh onboarding window
        // opened AFTER permissions were granted externally must still surface the
        // restart guidance when a helper session predates the grant. Latched so it
        // stays shown for the rest of this presentation.
        if agentSessionRequiresRestart(), newAccessibilityGranted, newScreenRecordingGranted {
            restartRequired = true
        }
        accessibilityGranted = newAccessibilityGranted
        screenRecordingGranted = newScreenRecordingGranted

        // Auto-advance the moment the current step's permission lands, so the flow
        // walks the user forward one permission at a time without extra clicks.
        if step == 1, newAccessibilityGranted {
            step = 2
        } else if step == 2, newScreenRecordingGranted {
            step = 3
        }
    }
}
