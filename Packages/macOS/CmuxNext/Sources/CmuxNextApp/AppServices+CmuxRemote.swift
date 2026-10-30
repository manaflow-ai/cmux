import CmuxNextComputerUse
import CmuxNextDaemon
import CmuxNextMacScreen
import CmuxNextSettings

extension AppServices {
    var cmuxRemoteActions: CmuxRemoteActionEnvironment {
        CmuxRemoteActionEnvironment(remote: cmuxRemote, hub: { [weak self] in self?.macScreenPages.hub },
                                    window: { [weak self] in self?.windows.active?.window },
                                    openDevices: { [weak self] in try? self?.settingsWindow.show(section: nil, route: "devices") })
    }

    /// cmux Remote (docs/cmux-remote.md): the daemon's signed host for Computer Use and Screen
    /// Sharing; ``CmuxRemoteService`` does the work, this only passes it the app's parts.
    func startCmuxRemote(_ settings: SettingsController) {
        let bundleID = environment.launch.bundleID ?? "com.cmuxterm.app.next"
        let auth = cloud.auth
        guard let devices = cmuxRemote.start(bundleID: bundleID, deviceHub: deviceHub, pages: macScreenPages,
                                             computerUse: ComputerUseHelperDaemon.shared.upstream,
                                             tokens: { try await auth.tokens().access }) else { return }
        let consent = joinConsent, previous = consent.changed
        consent.changed = { [weak consent] in
            previous()
            guard let consent else { return }
            let (on, view, full) = (consent.enabled, consent.permitsMacScreen(control: false), consent.permitsMacScreen(control: true))
            // task-owner: one consent line to the worker; it serves with the app quit too.
            Task { await devices.consent(enabled: on, view: view, full: full) }
        }
        cmuxRemote.follow(settings) { [weak self, weak settings] in
            guard let self, let settings else { return (false, false, true) }
            let computerUse = settings.snapshot.computerUse
            _ = daemon.identity?.capabilities.count // a reconnected daemon sends the switches again
            return (computerUse.enabled && computerUse.driver == .upstream && !registry.disabledFeatures.contains(.computerUse),
                    cloud.isSignedIn, settings.snapshot.remote.headless)
        }
    }
}
