extension ControlCommandCoordinator {
    // MARK: - Auxiliary debug windows

    func debugShowProWelcomeChecklist() -> ControlCallResult {
        guard let debugContext else {
            return .err(code: "unavailable", message: "Control context unavailable", data: nil)
        }
        debugContext.controlDebugShowProWelcomeChecklist()
        return .ok(.object(["shown": .bool(true)]))
    }

    func debugShowAndroidEmulators() -> ControlCallResult {
        guard let debugContext else {
            return .err(code: "unavailable", message: "Control context unavailable", data: nil)
        }
        debugContext.controlDebugShowAndroidEmulators()
        return .ok(.object(["shown": .bool(true)]))
    }

    func debugOpenRunningAndroidEmulator() -> ControlCallResult {
        guard let debugContext else {
            return .err(code: "unavailable", message: "Control context unavailable", data: nil)
        }
        return .ok(.object(["opened": .bool(debugContext.controlDebugOpenRunningAndroidEmulator())]))
    }
}
