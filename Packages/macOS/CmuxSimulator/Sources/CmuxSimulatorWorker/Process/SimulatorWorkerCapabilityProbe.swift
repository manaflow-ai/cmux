import CmuxSimulator

struct SimulatorWorkerCapabilityProbe: Equatable, Sendable {
    var hasFramebuffer = false
    var hasTouch = false
    var hasKeyboard = false
    var hasHostInputCapture = false
    var hasLegacyButtons = false
    var hasArbitraryButtons = false
    var hasRotation = false
    var hasDigitalCrown = false
    var hasMemoryWarning = false
    var hasCoreAnimationDiagnostics = false
    var hasAccessibility = false
    var hasForegroundApplication = false
    var hasCameraInjection = false
    var hasExtendedPermissions = false
    var hasWebInspector = false

    var capabilities: Set<SimulatorCapability> {
        var result: Set<SimulatorCapability> = []
        if hasFramebuffer { result.insert(.framebuffer) }
        if hasTouch {
            result.insert(.touch)
            result.insert(.multiTouch)
        }
        if hasKeyboard { result.insert(.keyboard) }
        if hasHostInputCapture { result.insert(.hostInputCapture) }
        if hasLegacyButtons || hasArbitraryButtons {
            result.insert(.hardwareButtons)
        }
        if hasRotation { result.insert(.rotation) }
        if hasDigitalCrown { result.insert(.digitalCrown) }
        if hasMemoryWarning { result.insert(.memoryWarning) }
        if hasCoreAnimationDiagnostics { result.insert(.coreAnimationDiagnostics) }
        if hasAccessibility { result.insert(.accessibility) }
        if hasForegroundApplication { result.insert(.foregroundApplication) }
        if hasCameraInjection { result.insert(.cameraInjection) }
        if hasExtendedPermissions { result.insert(.extendedPermissions) }
        if hasWebInspector { result.insert(.webInspector) }
        return result
    }
}
