import CmuxSimulator
import SwiftUI

struct SimulatorNotificationPrivacyTools: View {
    let coordinator: SimulatorPaneCoordinator

    var body: some View {
        SimulatorNotificationPrivacyToolsContent(coordinator: coordinator)
            .id(coordinator.selectedDeviceID)
    }
}

private struct SimulatorNotificationPrivacyToolsContent: View {
    let coordinator: SimulatorPaneCoordinator
    @State private var bundleIdentifier = ""
    @State private var service: SimulatorPrivacyService = .all

    var body: some View {
        SimulatorToolSection(simulatorStrings.notificationsAndPrivacy) {
            TextField(String(localized: simulatorStrings.bundleIdentifier), text: $bundleIdentifier)
            Button(simulatorStrings.sendPush) {
                coordinator.scheduleControlAction("push-notification") {
                    await $0.pushNotification(bundleIdentifier: bundleIdentifier)
                }
            }
            .disabled(bundleIdentifier.isEmpty)
            Divider()
            Picker(simulatorStrings.privacyService, selection: $service) {
                ForEach(SimulatorPrivacyService.allCases, id: \.rawValue) { service in
                    Text(simulatorStrings.privacy(service)).tag(service)
                }
            }
            HStack {
                Button(simulatorStrings.grant) { apply(.grant) }
                    .disabled(!simulatorPrivacyActionIsEnabled(
                        .grant,
                        service: service,
                        bundleIdentifier: bundleIdentifier
                    ))
                Button(simulatorStrings.revoke) { apply(.revoke) }
                    .disabled(!simulatorPrivacyActionIsEnabled(
                        .revoke,
                        service: service,
                        bundleIdentifier: bundleIdentifier
                    ))
                Button(simulatorStrings.reset) { apply(.reset) }
                    .disabled(!simulatorPrivacyActionIsEnabled(
                        .reset,
                        service: service,
                        bundleIdentifier: bundleIdentifier
                    ))
                Button(simulatorStrings.readPermissions) {
                    coordinator.scheduleControlAction("read-privacy") {
                        await $0.readPrivacy(bundleIdentifier: bundleIdentifier)
                    }
                }
            }
            if let snapshot = coordinator.privacySnapshot {
                ForEach(
                    snapshot.authorizations.keys.sorted { $0.rawValue < $1.rawValue },
                    id: \.rawValue
                ) { service in
                    if let authorization = snapshot.authorizations[service] {
                        LabeledContent(
                            String(localized: simulatorStrings.privacy(service)),
                            value: String(localized: simulatorStrings.authorization(authorization))
                        )
                    }
                }
            }
        }
        .task {
            if coordinator.supports(.foregroundApplication) {
                await coordinator.refreshForegroundApplication()
            }
            adoptForegroundBundleIfEmpty(coordinator.foregroundApplication?.bundleIdentifier)
        }
        .onChange(of: coordinator.foregroundApplication?.bundleIdentifier) { _, identifier in
            adoptForegroundBundleIfEmpty(identifier)
        }
    }

    private func apply(_ action: SimulatorPrivacyAction) {
        let target = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard simulatorPrivacyActionIsEnabled(
            action,
            service: service,
            bundleIdentifier: target
        ) else { return }
        coordinator.scheduleControlAction("set-privacy") {
            await $0.setPrivacy(
                action,
                service: service,
                bundleIdentifier: target
            )
        }
    }

    private func adoptForegroundBundleIfEmpty(_ foregroundBundleIdentifier: String?) {
        bundleIdentifier = simulatorPrivacyBundleIdentifier(
            current: bundleIdentifier,
            foreground: foregroundBundleIdentifier
        )
    }
}

func simulatorPrivacyActionIsEnabled(
    _ action: SimulatorPrivacyAction,
    service: SimulatorPrivacyService,
    bundleIdentifier: String
) -> Bool {
    guard !bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return false
    }
    return switch action {
    case .grant, .revoke:
        service != .all
    case .reset:
        true
    }
}

func simulatorPrivacyBundleIdentifier(current: String, foreground: String?) -> String {
    guard current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          let foreground = foreground?.trimmingCharacters(in: .whitespacesAndNewlines),
          !foreground.isEmpty else { return current }
    return foreground
}
