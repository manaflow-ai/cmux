import CmuxSimulator

extension SimulatorCameraAdapter {
    func setMirrorMode(_ mode: SimulatorCameraMirrorMode) -> Bool {
        mirrorMode = mode
        guard let surfaceRing else { return true }
        applyMirrorMode(to: surfaceRing)
        return true
    }

    func status() -> SimulatorCameraStatus {
        let attachmentPIDs = Set(
            surfaceRing?.injectorAttachments()
                .filter(\.isAttached)
                .compactMap(\.processIdentifier) ?? []
        )
        let liveBundles = injectedProcessIdentifiers.compactMap { bundle, processIdentifier in
            attachmentPIDs.contains(processIdentifier) ? bundle : nil
        }.sorted()
        let targets = simulatorCameraTargetStatuses(
            configuredBundleIdentifiers: injectedBundleIdentifiers,
            processIdentifiers: injectedProcessIdentifiers,
            attachedProcessIdentifiers: attachmentPIDs
        )
        let activePID = activeTargetBundleIdentifier.flatMap {
            injectedProcessIdentifiers[$0]
        } ?? activeTargetProcessIdentifier
        let processMatches = activePID.map(attachmentPIDs.contains) == true
        let targetIsAttached = activeTargetBundleIdentifier != nil && processMatches
        let targetIsAlive = activeTargetBundleIdentifier.flatMap {
            injectedProcessIdentifiers[$0]
        } != nil
        return SimulatorCameraStatus(
            configuration: activeConfiguration,
            mirrorMode: mirrorMode,
            injectedBundleIdentifiers: liveBundles,
            targetBundleIdentifier: activeTargetBundleIdentifier,
            targetProcessIdentifier: activePID,
            targetIsAlive: targetIsAlive,
            targetIsAttached: targetIsAttached,
            targets: targets,
            hostCameras: hostCameraDevicesOperation()
        )
    }

    func applyMirrorMode(to ring: SimulatorCameraSurfaceRing) {
        switch mirrorMode {
        case .auto:
            ring.setMirrored(nil)
        case .on:
            ring.setMirrored(true)
        case .off:
            ring.setMirrored(false)
        }
    }
}
