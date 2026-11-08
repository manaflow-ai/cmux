extension ControlCommandCoordinator {
    nonisolated func simulatorToken(
        _ params: [String: JSONValue],
        _ key: String
    ) -> String? {
        guard let value = string(params, key) else { return nil }
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty,
              bytes.count <= controlSimulatorMaximumCommandTokenUTF8ByteCount,
              simulatorASCIILowerAlphaNumeric(bytes[0]),
              bytes.allSatisfy({
                  simulatorASCIILowerAlphaNumeric($0) || $0 == 0x2D
              }) else { return nil }
        return value
    }

    nonisolated func simulatorBundleIdentifier(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty,
              bytes.count <= controlSimulatorMaximumBundleIdentifierUTF8ByteCount,
              simulatorASCIIAlphaNumeric(bytes[0]) else { return false }
        return bytes.allSatisfy {
            simulatorASCIIAlphaNumeric($0) || $0 == 0x2D || $0 == 0x2E
        }
    }

    private nonisolated func simulatorASCIIAlphaNumeric(_ value: UInt8) -> Bool {
        (0x30...0x39).contains(value)
            || (0x41...0x5A).contains(value)
            || (0x61...0x7A).contains(value)
    }

    private nonisolated func simulatorASCIILowerAlphaNumeric(_ value: UInt8) -> Bool {
        (0x30...0x39).contains(value) || (0x61...0x7A).contains(value)
    }

    nonisolated func simulatorButtonName(_ raw: String) -> String {
        let normalized = raw.lowercased()
        return switch normalized {
        case "swipe-home", "swipe_home", "swipehome": "swipeHome"
        case "app-switcher", "app_switcher", "appswitcher": "appSwitcher"
        case "side-button", "side_button", "sidebutton": "sideButton"
        case "volume-up", "volume_up", "volumeup": "volumeUp"
        case "volume-down", "volume_down", "volumedown": "volumeDown"
        case "watch-side-button", "watch_side_button", "watchsidebutton": "watchSideButton"
        default: normalized
        }
    }

    nonisolated func simulatorCADiagnosticName(_ raw: String) -> String {
        let normalized = raw.lowercased()
        return switch normalized {
        case "slow-animations", "slow_animations", "slowanimations": "slowAnimations"
        default: normalized
        }
    }

    nonisolated func simulatorSwipe(
        _ params: [String: JSONValue]
    ) -> [ControlSimulatorTouch]? {
        guard let fromX = simulatorDouble(params, "from_x"),
              let fromY = simulatorDouble(params, "from_y"),
              let toX = simulatorDouble(params, "to_x"),
              let toY = simulatorDouble(params, "to_y"),
              simulatorCoordinate(fromX), simulatorCoordinate(fromY),
              simulatorCoordinate(toX), simulatorCoordinate(toY) else { return nil }
        let steps = simulatorInt(params, "steps") ?? 8
        guard (2...64).contains(steps) else { return nil }
        let fromX2 = simulatorDouble(params, "from_x2")
        let fromY2 = simulatorDouble(params, "from_y2")
        let toX2 = simulatorDouble(params, "to_x2")
        let toY2 = simulatorDouble(params, "to_y2")
        let secondaryValues = [fromX2, fromY2, toX2, toY2]
        guard secondaryValues.allSatisfy({ $0 == nil }) || secondaryValues.allSatisfy({ $0 != nil }),
              secondaryValues.compactMap({ $0 }).allSatisfy(simulatorCoordinate),
              let edge = simulatorTouchEdge(params) else { return nil }
        return (0...steps).map { index in
            let progress = Double(index) / Double(steps)
            let phase = index == 0 ? "began" : (index == steps ? "ended" : "moved")
            return ControlSimulatorTouch(
                phase: phase,
                x: fromX + (toX - fromX) * progress,
                y: fromY + (toY - fromY) * progress,
                secondX: fromX2.map { $0 + ((toX2 ?? $0) - $0) * progress },
                secondY: fromY2.map { $0 + ((toY2 ?? $0) - $0) * progress },
                edge: edge
            )
        }
    }

    nonisolated func simulatorTouchEdge(
        _ params: [String: JSONValue]
    ) -> String? {
        let raw: String
        switch params["edge"] {
        case nil:
            raw = "none"
        case let .string(value):
            raw = value.lowercased()
        case let .int(value):
            raw = String(value)
        default:
            return nil
        }
        return switch raw {
        case "none", "0": "none"
        case "left", "1": "left"
        case "top", "2": "top"
        case "bottom", "3": "bottom"
        case "right", "4": "right"
        default: nil
        }
    }

    nonisolated func simulatorPermissionService(_ raw: String) -> String {
        switch raw.lowercased().replacingOccurrences(of: "_", with: "-") {
        case "push", "notification": "notifications"
        case "photo-library", "photo": "photos"
        case "location-in-use": "location-inuse"
        case "mic": "microphone"
        case "critical-notifications": "notifications-critical"
        case "face-id": "faceid"
        case "home-kit": "homekit"
        case let service: service
        }
    }

    nonisolated func simulatorInterfaceOption(_ raw: String) -> String {
        switch raw.lowercased().replacingOccurrences(of: "_", with: "-") {
        case "content-size": "text-size"
        case "button-shapes": "show-borders"
        case "voice-over": "voiceover"
        case let option: option
        }
    }

    nonisolated func simulatorCameraOperation(
        _ params: [String: JSONValue], targeted: Bool
    ) -> ControlSimulatorOperation? {
        guard let rawSource = string(params, "source") else { return nil }
        let source = rawSource.lowercased()
        let allowed = ["off", "disabled", "placeholder", "image", "file", "video", "host", "webcam"]
        guard allowed.contains(source) else { return nil }
        let path = string(params, "path")
        if ["image", "file", "video"].contains(source), path == nil { return nil }
        let bundleIdentifier = targeted ? string(params, "bundle_id") : nil
        if targeted, source != "off", source != "disabled", bundleIdentifier == nil { return nil }
        return .cameraConfigure(
            source: source,
            path: path,
            loops: simulatorBool(params, "loops") ?? ["file", "video"].contains(source),
            hostDeviceID: string(params, "device_id"),
            bundleIdentifier: bundleIdentifier
        )
    }
}
