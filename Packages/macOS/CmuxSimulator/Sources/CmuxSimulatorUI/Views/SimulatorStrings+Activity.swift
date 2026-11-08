import CmuxSimulator
import Foundation

extension SimulatorStrings {
    func screenshotFilename(_ fileExtension: String) -> LocalizedStringResource {
        LocalizedStringResource(
            "simulator.file.screenshotName",
            defaultValue: "Simulator Screenshot.\(fileExtension)",
            bundle: .main,
            comment: "Default filename for a Simulator screenshot, including its extension."
        )
    }

    var videoFilename: LocalizedStringResource {
        simulatorResource("simulator.file.videoName", "Simulator Recording.mp4")
    }

    func actionLog(_ action: String) -> LocalizedStringResource {
        switch action {
        case "pointer": simulatorResource("simulator.activity.touch", "Touch")
        case "key": simulatorResource("simulator.activity.keyboard", "Keyboard")
        case "type_text": simulatorResource("simulator.activity.typeText", "Type Text")
        case "button": simulatorResource("simulator.activity.hardwareButton", "Hardware Button")
        case "rotate": simulatorResource("simulator.activity.rotate", "Rotate")
        case "digital_crown": simulatorResource("simulator.activity.digitalCrown", "Digital Crown")
        case "software_keyboard": simulatorResource("simulator.activity.softwareKeyboard", "Software Keyboard")
        case "memory_warning": simulatorResource("simulator.activity.memoryWarning", "Memory Warning")
        case "core_animation_diagnostic": simulatorResource("simulator.activity.coreAnimation", "Core Animation Diagnostic")
        case "camera": simulatorResource("simulator.activity.camera", "Camera")
        case "camera_mirror": simulatorResource("simulator.activity.cameraMirror", "Camera Mirror")
        case "privacy": simulatorResource("simulator.activity.privacy", "Privacy")
        case "privacy_status": simulatorResource("simulator.activity.privacyStatus", "Privacy Status")
        case "react_native_reload": simulatorResource("simulator.activity.reactNativeReload", "React Native Reload")
        case "accessibility_highlight": simulatorResource("simulator.activity.accessibilityHighlight", "Accessibility Highlight")
        case "accessibility": simulatorResource("simulator.activity.accessibility", "Accessibility Inspection")
        case "camera_status": simulatorResource("simulator.activity.cameraStatus", "Camera Status")
        case "camera_configuration": simulatorResource("simulator.activity.cameraConfiguration", "Camera Configuration")
        case "foreground_application": simulatorResource("simulator.activity.foregroundApplication", "Foreground App")
        case "private_interface": simulatorResource("simulator.activity.interface", "Appearance or Accessibility")
        case "private_interface_status": simulatorResource("simulator.activity.interfaceStatus", "Appearance Status")
        case "applications": simulatorResource("simulator.activity.applications", "Applications")
        case "open_url": simulatorResource("simulator.activity.openURL", "Open URL")
        case "media": simulatorResource("simulator.activity.media", "Media")
        case "clipboard": simulatorResource("simulator.activity.clipboard", "Clipboard")
        case "location": simulatorResource("simulator.activity.location", "Location")
        case "push_notification": simulatorResource("simulator.activity.pushNotification", "Push Notification")
        case "status_bar": simulatorResource("simulator.activity.statusBar", "Status Bar")
        case "interface": simulatorResource("simulator.activity.interface", "Appearance or Accessibility")
        case "capture": simulatorResource("simulator.activity.capture", "Capture")
        case "logs": simulatorResource("simulator.activity.logs", "Logs")
        case "web_inspector_targets": simulatorResource(
            "simulator.activity.webInspectorTargets",
            "Web Inspector Targets"
        )
        case "web_inspector_attach": simulatorResource(
            "simulator.activity.webInspectorAttach",
            "Web Inspector Attach"
        )
        case "web_inspector_release": simulatorResource(
            "simulator.activity.webInspectorRelease",
            "Web Inspector Release"
        )
        case "web_inspector_highlight": simulatorResource(
            "simulator.activity.webInspectorHighlight",
            "Web Inspector Highlight"
        )
        case "web_inspector_command": simulatorResource(
            "simulator.activity.webInspectorCommand",
            "Web Inspector Command"
        )
        default: activityAction
        }
    }

    func accessibilityRootCount(_ count: Int) -> LocalizedStringResource {
        LocalizedStringResource(
            "simulator.accessibility.rootCount",
            defaultValue: "Accessibility roots: \(count)",
            bundle: .main,
            comment: "Count of top-level elements in the simulated app accessibility tree."
        )
    }

    func failure(_ code: String) -> LocalizedStringResource {
        switch code {
        case "device_discovery_failed", "invalid_simctl_json", "invalid_application_list":
            simulatorResource("simulator.failure.deviceDiscovery", "Could not load Simulator devices")
        case "device_activation_failed", "device_not_booted", "device_not_found",
             "worker_attach_failed":
            simulatorResource("simulator.failure.deviceActivation", "Could not start the selected Simulator")
        case "framework_unavailable", "private_api_unavailable", "framebuffer_unavailable":
            simulatorResource("simulator.failure.rendererUnavailable", "The Simulator renderer is unavailable")
        case "worker_stopped", "worker_crash_fuse", "worker_unavailable", "worker_send_failed",
             "worker_response_timed_out":
            simulatorResource("simulator.failure.rendererStopped", "The Simulator renderer stopped")
        case "input_unavailable", "text_input_delivery_unavailable":
            simulatorResource("simulator.failure.inputUnavailable", "Simulator input is unavailable")
        case "text_input_empty":
            simulatorResource("simulator.failure.textEmpty", "Enter text to type")
        case "text_input_too_long":
            simulatorResource("simulator.failure.textTooLong", "Text is too long to type")
        case "text_input_unsupported_character":
            simulatorResource(
                "simulator.failure.textUnsupported",
                "Text contains a character that cannot be typed with a US keyboard"
            )
        case "camera_configuration_failed", "camera_injection_unavailable", "camera_mirror_failed",
             "camera_source_switch_failed", "camera_ownership_busy":
            simulatorResource("simulator.failure.cameraUnavailable", "The camera action is unavailable")
        case "extended_permission_unavailable", "private_permission_failed",
             "unsupported_private_permission":
            simulatorResource("simulator.failure.permissionUnavailable", "The permission action is unavailable")
        case "invalid_location", "invalid_location_route", "location_route_not_paused",
             "location_route_not_running":
            simulatorResource("simulator.failure.locationUnavailable", "The location action could not be completed")
        case "react_native_reload_failed":
            simulatorResource("simulator.failure.reactNativeReload", "React Native could not be reloaded")
        case "accessibility_highlight_failed", "accessibility_unavailable":
            simulatorResource("simulator.failure.accessibilityUnavailable", "Accessibility inspection is unavailable")
        case "web_inspector_failed", "web_inspector_unavailable", "web_inspector_attach_failed",
             "web_inspector_highlight_failed", "web_inspector_command_rejected",
             "web_inspector_response_overflow":
            simulatorResource("simulator.failure.webInspectorUnavailable", "Web Inspector is unavailable")
        default:
            controlFailed
        }
    }
}
