import Foundation
import CmuxSimulator

func simulatorResource(
    _ key: StaticString,
    _ defaultValue: String.LocalizationValue
) -> LocalizedStringResource {
    LocalizedStringResource(key, defaultValue: defaultValue, bundle: .main)
}

struct SimulatorStrings {
    let simulator = LocalizedStringResource(
        "simulator.pane.title",
        defaultValue: "Simulator",
        bundle: .main,
        comment: "Title for the native iPhone and iPad Simulator pane."
    )
    let chooseDevice = LocalizedStringResource(
        "simulator.device.choose",
        defaultValue: "Choose Device",
        bundle: .main,
        comment: "Button that opens the Simulator device picker."
    )
    let noDevices = LocalizedStringResource(
        "simulator.device.none",
        defaultValue: "No iPhone or iPad Simulators",
        bundle: .main,
        comment: "Empty state when Xcode has no usable iPhone or iPad Simulator devices."
    )
    let noDevicesHelp = LocalizedStringResource(
        "simulator.device.none.help",
        defaultValue: "Install an iOS runtime in Xcode, then refresh.",
        bundle: .main,
        comment: "Help text for the empty Simulator device state."
    )
    let refresh = LocalizedStringResource(
        "simulator.action.refresh",
        defaultValue: "Refresh",
        bundle: .main,
        comment: "Button that refreshes Simulator data."
    )
    let reconnect = LocalizedStringResource(
        "simulator.action.reconnect",
        defaultValue: "Reconnect",
        bundle: .main,
        comment: "Button that restarts a failed Simulator pane connection."
    )
    let tools = LocalizedStringResource(
        "simulator.tools.title",
        defaultValue: "Simulator Tools",
        bundle: .main,
        comment: "Title for the native Simulator tools inspector."
    )
    let rotateLeft = LocalizedStringResource(
        "simulator.action.rotateLeft",
        defaultValue: "Rotate Left",
        bundle: .main,
        comment: "Toolbar button that rotates the simulated device left."
    )
    let rotateRight = LocalizedStringResource(
        "simulator.action.rotateRight",
        defaultValue: "Rotate Right",
        bundle: .main,
        comment: "Toolbar button that rotates the simulated device right."
    )
    let keyboard = LocalizedStringResource(
        "simulator.action.keyboard",
        defaultValue: "Software Keyboard",
        bundle: .main,
        comment: "Toolbar button that toggles the simulated software keyboard."
    )
    let home = LocalizedStringResource(
        "simulator.action.home",
        defaultValue: "Home",
        bundle: .main,
        comment: "Toolbar button that performs the Simulator Home action."
    )
    let capturePointer = LocalizedStringResource(
        "simulator.action.capturePointer",
        defaultValue: "Capture Pointer and Keyboard (Escape to Release)",
        bundle: .main,
        comment: "Button that routes the Mac pointer and keyboard to an iPad Simulator."
    )
    let captureKeyboard = LocalizedStringResource(
        "simulator.action.captureKeyboard",
        defaultValue: "Capture Keyboard (Escape to Release)",
        bundle: .main,
        comment: "Button that routes the Mac keyboard to an iPad Simulator."
    )
    let appSwitcher = LocalizedStringResource(
        "simulator.action.appSwitcher",
        defaultValue: "App Switcher",
        bundle: .main,
        comment: "Toolbar button that opens the simulated app switcher."
    )
    let lock = LocalizedStringResource(
        "simulator.action.lock",
        defaultValue: "Lock",
        bundle: .main,
        comment: "Toolbar button that locks the simulated device."
    )
    let connecting = LocalizedStringResource(
        "simulator.status.connecting",
        defaultValue: "Connecting",
        bundle: .main,
        comment: "Status while cmux attaches to a Simulator."
    )
    let streaming = LocalizedStringResource(
        "simulator.status.streaming",
        defaultValue: "Live",
        bundle: .main,
        comment: "Status while the Simulator display is live."
    )
    let unavailable = LocalizedStringResource(
        "simulator.status.unavailable",
        defaultValue: "Device Unavailable",
        bundle: .main,
        comment: "Status when the selected Simulator cannot be attached."
    )
    let workerStopped = LocalizedStringResource(
        "simulator.status.workerStopped",
        defaultValue: "Simulator Renderer Stopped",
        bundle: .main,
        comment: "Status when the isolated Simulator renderer exits unexpectedly."
    )
    let failed = LocalizedStringResource(
        "simulator.status.failed",
        defaultValue: "Simulator Connection Failed",
        bundle: .main,
        comment: "Status when the Simulator pane cannot connect."
    )
    let selectToStart = LocalizedStringResource(
        "simulator.status.selectToStart",
        defaultValue: "Select a device to start",
        bundle: .main,
        comment: "Idle text before a Simulator device is selected."
    )
    let device = LocalizedStringResource(
        "simulator.tools.device",
        defaultValue: "Device",
        bundle: .main,
        comment: "Simulator tools section title for device information."
    )
    let hardware = LocalizedStringResource(
        "simulator.tools.hardware",
        defaultValue: "Hardware",
        bundle: .main,
        comment: "Simulator tools section title for hardware buttons."
    )
    let diagnostics = LocalizedStringResource(
        "simulator.tools.diagnostics",
        defaultValue: "Diagnostics",
        bundle: .main,
        comment: "Simulator tools section title for diagnostics."
    )
    let inspect = LocalizedStringResource(
        "simulator.tools.inspect",
        defaultValue: "Inspect",
        bundle: .main,
        comment: "Simulator tools section title for app and accessibility inspection."
    )
    let activity = LocalizedStringResource(
        "simulator.tools.activity",
        defaultValue: "Activity",
        bundle: .main,
        comment: "Simulator tools section title for recent actions."
    )
    let memoryWarning = LocalizedStringResource(
        "simulator.action.memoryWarning",
        defaultValue: "Memory Warning",
        bundle: .main,
        comment: "Button that sends a memory warning to the simulated app."
    )
    let terminateRenderer = simulatorResource(
        "simulator.action.terminateRenderer",
        "Terminate Renderer"
    )
    let accessibility = LocalizedStringResource(
        "simulator.action.accessibility",
        defaultValue: "Accessibility Tree",
        bundle: .main,
        comment: "Button that inspects the simulated app accessibility tree."
    )
    let foregroundApp = LocalizedStringResource(
        "simulator.action.foregroundApp",
        defaultValue: "Foreground App",
        bundle: .main,
        comment: "Button that inspects the foreground simulated app."
    )
    let processIdentifier = simulatorResource("simulator.application.processIdentifier", "Process ID")
    let version = simulatorResource("simulator.application.version", "Version")
    let build = simulatorResource("simulator.application.build", "Build")
    let minimumOSVersion = simulatorResource("simulator.application.minimumOS", "Minimum OS")
    let executable = simulatorResource("simulator.application.executable", "Executable")
    let applicationPath = simulatorResource("simulator.application.path", "App Path")
    let revealInFinder = simulatorResource("simulator.action.revealInFinder", "Reveal in Finder")
    let reactNative = simulatorResource("simulator.application.reactNative", "React Native")
    let yes = simulatorResource("simulator.value.yes", "Yes")
    let no = simulatorResource("simulator.value.no", "No")
    let shutdown = LocalizedStringResource(
        "simulator.action.shutdown",
        defaultValue: "Shut Down Device",
        bundle: .main,
        comment: "Button that shuts down the selected Simulator device."
    )
    let crownUp = LocalizedStringResource(
        "simulator.action.crownUp",
        defaultValue: "Crown Up",
        bundle: .main,
        comment: "Button that turns the Apple Watch Digital Crown upward."
    )
    let crownDown = LocalizedStringResource(
        "simulator.action.crownDown",
        defaultValue: "Crown Down",
        bundle: .main,
        comment: "Button that turns the Apple Watch Digital Crown downward."
    )
    let runtime = simulatorResource("simulator.device.runtime", "Runtime")
    let state = simulatorResource("simulator.device.state", "State")
    let udid = simulatorResource("simulator.device.udid", "UDID")
    let sideButton = simulatorResource("simulator.action.sideButton", "Side Button")
    let volumeUp = simulatorResource("simulator.action.volumeUp", "Volume Up")
    let volumeDown = simulatorResource("simulator.action.volumeDown", "Volume Down")
    let swipeHome = simulatorResource("simulator.action.swipeHome", "Swipe Home")
    let siri = simulatorResource("simulator.action.siri", "Siri")
    let colorBlendedLayers = simulatorResource(
        "simulator.diagnostic.colorBlendedLayers",
        "Color Blended Layers"
    )
    let colorCopiedImages = simulatorResource(
        "simulator.diagnostic.colorCopiedImages",
        "Color Copied Images"
    )
    let colorMisalignedImages = simulatorResource(
        "simulator.diagnostic.colorMisalignedImages",
        "Color Misaligned Images"
    )
    let colorOffscreenRendering = simulatorResource(
        "simulator.diagnostic.colorOffscreenRendering",
        "Color Offscreen Rendering"
    )
    let slowAnimations = simulatorResource("simulator.diagnostic.slowAnimations", "Slow Animations")
    let noActivity = simulatorResource("simulator.activity.empty", "No recent activity")
    let activityAction = simulatorResource("simulator.activity.action", "Simulator Action")
    let applications = simulatorResource("simulator.tools.applications", "Applications")
    let installApplication = simulatorResource("simulator.action.installApplication", "Install App or IPA")
    let launch = simulatorResource("simulator.action.launch", "Launch")
    let terminate = simulatorResource("simulator.action.terminate", "Terminate")
    let launchArguments = simulatorResource("simulator.application.arguments", "Launch Arguments")
    let waitForDebugger = simulatorResource("simulator.application.waitForDebugger", "Wait for Debugger")
    let terminateRunning = simulatorResource("simulator.application.terminateRunning", "Terminate Running App")
    let urlAndMedia = simulatorResource("simulator.tools.urlAndMedia", "URL and Media")
    let url = simulatorResource("simulator.field.url", "URL")
    let openURL = simulatorResource("simulator.action.openURL", "Open URL")
    let addMedia = simulatorResource("simulator.action.addMedia", "Add Media")
    let clipboard = simulatorResource("simulator.tools.clipboard", "Clipboard")
    let readClipboard = simulatorResource("simulator.action.readClipboard", "Read")
    let writeClipboard = simulatorResource("simulator.action.writeClipboard", "Write")
    let syncClipboard = simulatorResource("simulator.action.syncClipboard", "Copy from Mac")
    let location = simulatorResource("simulator.tools.location", "Location")
    let latitude = simulatorResource("simulator.field.latitude", "Latitude")
    let longitude = simulatorResource("simulator.field.longitude", "Longitude")
    let destinationLatitude = simulatorResource("simulator.field.destinationLatitude", "Destination Latitude")
    let destinationLongitude = simulatorResource("simulator.field.destinationLongitude", "Destination Longitude")
    let routeSpeed = simulatorResource("simulator.field.routeSpeed", "Speed (m/s)")
    let setLocation = simulatorResource("simulator.action.setLocation", "Set Location")
    let startRoute = simulatorResource("simulator.action.startRoute", "Start Route")
    let clearLocation = simulatorResource("simulator.action.clearLocation", "Clear Location")
    let pauseRoute = simulatorResource("simulator.action.pauseRoute", "Pause Route")
    let resumeRoute = simulatorResource("simulator.action.resumeRoute", "Resume Route")
    let stopRoute = simulatorResource("simulator.action.stopRoute", "Stop Route")
    let notificationsAndPrivacy = simulatorResource(
        "simulator.tools.notificationsAndPrivacy",
        "Notifications and Privacy"
    )
    let bundleIdentifier = simulatorResource("simulator.field.bundleIdentifier", "Bundle Identifier")
    let sendPush = simulatorResource("simulator.action.sendPush", "Send Push Payload")
    let privacyService = simulatorResource("simulator.field.privacyService", "Privacy Service")
    let grant = simulatorResource("simulator.privacy.grant", "Grant")
    let revoke = simulatorResource("simulator.privacy.revoke", "Revoke")
    let reset = simulatorResource("simulator.privacy.reset", "Reset")
    let readPermissions = simulatorResource("simulator.privacy.read", "Read Status")
    let appearance = simulatorResource("simulator.tools.appearance", "Appearance and Status Bar")
    let light = simulatorResource("simulator.appearance.light", "Light")
    let dark = simulatorResource("simulator.appearance.dark", "Dark")
    let increaseContrast = simulatorResource("simulator.appearance.increaseContrast", "Increase Contrast")
    let liquidGlass = simulatorResource("simulator.appearance.liquidGlass", "Liquid Glass")
    let clear = simulatorResource("simulator.appearance.clear", "Clear")
    let tinted = simulatorResource("simulator.appearance.tinted", "Tinted")
    let colorFilter = simulatorResource("simulator.appearance.colorFilter", "Color Filter")
    let reduceMotion = simulatorResource("simulator.appearance.reduceMotion", "Reduce Motion")
    let buttonShapes = simulatorResource("simulator.appearance.buttonShapes", "Button Shapes")
    let reduceTransparency = simulatorResource(
        "simulator.appearance.reduceTransparency",
        "Reduce Transparency"
    )
    let voiceOver = simulatorResource("simulator.appearance.voiceOver", "VoiceOver")
    let contentSize = simulatorResource("simulator.appearance.contentSize", "Text Size")
    let statusTime = simulatorResource("simulator.statusBar.time", "Time")
    let carrier = simulatorResource("simulator.statusBar.carrier", "Carrier")
    let batteryLevel = simulatorResource("simulator.statusBar.batteryLevel", "Battery Level")
    let dataNetwork = simulatorResource("simulator.statusBar.dataNetwork", "Data Network")
    let wifiMode = simulatorResource("simulator.statusBar.wifiMode", "Wi-Fi")
    let wifiBars = simulatorResource("simulator.statusBar.wifiBars", "Wi-Fi Bars")
    let cellularMode = simulatorResource("simulator.statusBar.cellularMode", "Cellular")
    let cellularBars = simulatorResource("simulator.statusBar.cellularBars", "Cellular Bars")
    let batteryState = simulatorResource("simulator.statusBar.batteryState", "Battery State")
    let applyStatusBar = simulatorResource("simulator.action.applyStatusBar", "Apply Status Bar")
    let clearStatusBar = simulatorResource("simulator.action.clearStatusBar", "Clear Status Bar")
    let capture = simulatorResource("simulator.tools.capture", "Capture")
    let screenshot = simulatorResource("simulator.action.screenshot", "Screenshot")
    let startRecording = simulatorResource("simulator.action.startRecording", "Start Recording")
    let stopRecording = simulatorResource("simulator.action.stopRecording", "Stop Recording")
    let logs = simulatorResource("simulator.tools.logs", "Logs")
    let recentLogs = simulatorResource("simulator.action.recentLogs", "Load Recent Logs")
    let startLogStream = simulatorResource("simulator.action.startLogStream", "Stream Logs")
    let stopLogStream = simulatorResource("simulator.action.stopLogStream", "Stop Streaming")
    let cameraExperimental = simulatorResource(
        "simulator.tools.cameraExperimental",
        "Camera (Experimental)"
    )
    let chooseCameraSource = simulatorResource("simulator.action.chooseCameraSource", "Image or Video")
    let hostCamera = simulatorResource("simulator.action.hostCamera", "Use Mac Camera")
    let disableCamera = simulatorResource("simulator.action.disableCamera", "Disable Camera")
    let cameraPlaceholder = simulatorResource("simulator.action.cameraPlaceholder", "Animated Placeholder")
    let cameraMirror = simulatorResource("simulator.camera.mirror", "Mirror")
    let cameraMirrorAuto = simulatorResource("simulator.camera.mirror.auto", "Automatic")
    let cameraMirrorOn = simulatorResource("simulator.camera.mirror.on", "On")
    let cameraMirrorOff = simulatorResource("simulator.camera.mirror.off", "Off")
    let hostCameraDevice = simulatorResource("simulator.camera.hostDevice", "Mac Camera")
    let injectedApplications = simulatorResource("simulator.camera.injectedApplications", "Injected Apps")
    let cameraSource = simulatorResource("simulator.camera.source", "Source")
    let cameraSourceDisabled = simulatorResource("simulator.camera.source.disabled", "Disabled")
    let none = simulatorResource("simulator.value.none", "None")
    let experimentalHelp = simulatorResource(
        "simulator.camera.experimentalHelp",
        "Camera injection uses private Simulator interfaces and may stop working after an Xcode update."
    )
    let controlFailed = simulatorResource("simulator.control.failed", "Simulator action failed")
    let technicalDetails = simulatorResource("simulator.failure.technicalDetails", "Technical Details")
    let loading = simulatorResource("simulator.status.loading", "Working")
    let reloadReactNative = simulatorResource("simulator.action.reloadReactNative", "Reload React Native")
    let clearHighlight = simulatorResource("simulator.action.clearHighlight", "Clear Highlight")
    let webInspector = simulatorResource("simulator.tools.webInspector", "Web Inspector")
    let refreshTargets = simulatorResource("simulator.webInspector.refreshTargets", "Refresh Targets")
    let chooseTarget = simulatorResource("simulator.webInspector.chooseTarget", "Choose Target")
    let releaseInspector = simulatorResource("simulator.webInspector.release", "Release")
    let noInspectorTargets = simulatorResource(
        "simulator.webInspector.noTargets",
        "No inspectable pages"
    )
    let webInspectorUnavailable = simulatorResource(
        "simulator.webInspector.unavailable",
        "Web Inspector is unavailable for this Simulator"
    )
    let inUse = simulatorResource("simulator.webInspector.inUse", "In Use")
    let highlightPage = simulatorResource("simulator.webInspector.highlight", "Highlight Page")
    let unhighlightPage = simulatorResource("simulator.webInspector.unhighlight", "Remove Highlight")
    let sendInspectorCommand = simulatorResource("simulator.webInspector.send", "Send JSON")
    let rawInspectorRequest = simulatorResource(
        "simulator.webInspector.rawRequest",
        "Raw Web Inspector JSON Request"
    )
    let inspectorResponses = simulatorResource("simulator.webInspector.responses", "Responses")
    let clearInspectorResponses = simulatorResource(
        "simulator.webInspector.clearResponses",
        "Clear Responses"
    )
    let noInspectorResponses = simulatorResource(
        "simulator.webInspector.noResponses",
        "No inspector responses"
    )
    let truncatedInspectorResponse = simulatorResource(
        "simulator.webInspector.truncatedResponse",
        "Response truncated in this view"
    )

    func privacy(_ service: SimulatorPrivacyService) -> LocalizedStringResource {
        switch service {
        case .all: simulatorResource("simulator.privacy.all", "All Services")
        case .calendar: simulatorResource("simulator.privacy.calendar", "Calendars")
        case .contactsLimited: simulatorResource("simulator.privacy.contactsLimited", "Limited Contacts")
        case .contacts: simulatorResource("simulator.privacy.contacts", "Contacts")
        case .location: simulatorResource("simulator.privacy.location", "Location While Using")
        case .locationAlways: simulatorResource("simulator.privacy.locationAlways", "Location Always")
        case .locationInUse: simulatorResource("simulator.privacy.locationInUse", "Location While Using")
        case .photosAdd: simulatorResource("simulator.privacy.photosAdd", "Add Photos")
        case .photos: simulatorResource("simulator.privacy.photos", "Photos")
        case .photosLimited: simulatorResource("simulator.privacy.photosLimited", "Limited Photos")
        case .mediaLibrary: simulatorResource("simulator.privacy.mediaLibrary", "Media Library")
        case .microphone: simulatorResource("simulator.privacy.microphone", "Microphone")
        case .motion: simulatorResource("simulator.privacy.motion", "Motion")
        case .reminders: simulatorResource("simulator.privacy.reminders", "Reminders")
        case .siri: simulatorResource("simulator.privacy.siri", "Siri")
        case .camera: simulatorResource("simulator.privacy.camera", "Camera")
        case .notifications: simulatorResource("simulator.privacy.notifications", "Notifications")
        case .criticalNotifications: simulatorResource("simulator.privacy.criticalNotifications", "Critical Notifications")
        case .speech: simulatorResource("simulator.privacy.speech", "Speech Recognition")
        case .faceID: simulatorResource("simulator.privacy.faceID", "Face ID")
        case .userTracking: simulatorResource("simulator.privacy.userTracking", "App Tracking")
        case .homeKit: simulatorResource("simulator.privacy.homeKit", "HomeKit")
        }
    }

    func contentSize(_ size: SimulatorInterfaceSetting.ContentSize) -> LocalizedStringResource {
        switch size {
        case .extraSmall: simulatorResource("simulator.textSize.extraSmall", "Extra Small")
        case .small: simulatorResource("simulator.textSize.small", "Small")
        case .medium: simulatorResource("simulator.textSize.medium", "Medium")
        case .large: simulatorResource("simulator.textSize.large", "Large")
        case .extraLarge: simulatorResource("simulator.textSize.extraLarge", "Extra Large")
        case .extraExtraLarge: simulatorResource("simulator.textSize.extraExtraLarge", "XX Large")
        case .extraExtraExtraLarge: simulatorResource("simulator.textSize.extraExtraExtraLarge", "XXX Large")
        case .accessibilityMedium: simulatorResource("simulator.textSize.accessibilityMedium", "Accessibility Medium")
        case .accessibilityLarge: simulatorResource("simulator.textSize.accessibilityLarge", "Accessibility Large")
        case .accessibilityExtraLarge: simulatorResource("simulator.textSize.accessibilityExtraLarge", "Accessibility XL")
        case .accessibilityExtraExtraLarge: simulatorResource("simulator.textSize.accessibilityExtraExtraLarge", "Accessibility XXL")
        case .accessibilityExtraExtraExtraLarge: simulatorResource("simulator.textSize.accessibilityExtraExtraExtraLarge", "Accessibility XXXL")
        }
    }

    func colorFilter(_ filter: SimulatorInterfaceSetting.ColorFilter) -> LocalizedStringResource {
        switch filter {
        case .none: simulatorResource("simulator.colorFilter.none", "None")
        case .grayscale: simulatorResource("simulator.colorFilter.grayscale", "Grayscale")
        case .redGreen: simulatorResource("simulator.colorFilter.redGreen", "Red-Green")
        case .greenRed: simulatorResource("simulator.colorFilter.greenRed", "Green-Red")
        case .blueYellow: simulatorResource("simulator.colorFilter.blueYellow", "Blue-Yellow")
        }
    }

    func dataNetwork(_ network: SimulatorStatusBarOverride.DataNetwork) -> LocalizedStringResource {
        switch network {
        case .hide: simulatorResource("simulator.dataNetwork.hide", "Hidden")
        case .wifi: simulatorResource("simulator.dataNetwork.wifi", "Wi-Fi")
        case .threeG: simulatorResource("simulator.dataNetwork.threeG", "3G")
        case .fourG: simulatorResource("simulator.dataNetwork.fourG", "4G")
        case .lte: simulatorResource("simulator.dataNetwork.lte", "LTE")
        case .lteAdvanced: simulatorResource("simulator.dataNetwork.lteAdvanced", "LTE-A")
        case .ltePlus: simulatorResource("simulator.dataNetwork.ltePlus", "LTE+")
        case .fiveG: simulatorResource("simulator.dataNetwork.fiveG", "5G")
        case .fiveGPlus: simulatorResource("simulator.dataNetwork.fiveGPlus", "5G+")
        case .fiveGUWB: simulatorResource("simulator.dataNetwork.fiveGUWB", "5G UWB")
        case .fiveGUC: simulatorResource("simulator.dataNetwork.fiveGUC", "5G UC")
        }
    }

    func connection(_ mode: SimulatorStatusBarOverride.ConnectionMode) -> LocalizedStringResource {
        switch mode {
        case .searching: simulatorResource("simulator.connection.searching", "Searching")
        case .failed: simulatorResource("simulator.connection.failed", "Failed")
        case .active: simulatorResource("simulator.connection.active", "Active")
        }
    }

    func cellular(_ mode: SimulatorStatusBarOverride.CellularMode) -> LocalizedStringResource {
        switch mode {
        case .notSupported: simulatorResource("simulator.cellular.notSupported", "Not Supported")
        case .searching: simulatorResource("simulator.cellular.searching", "Searching")
        case .failed: simulatorResource("simulator.cellular.failed", "Failed")
        case .active: simulatorResource("simulator.cellular.active", "Active")
        }
    }

    func battery(_ state: SimulatorStatusBarOverride.BatteryState) -> LocalizedStringResource {
        switch state {
        case .charging: simulatorResource("simulator.battery.charging", "Charging")
        case .charged: simulatorResource("simulator.battery.charged", "Charged")
        case .discharging: simulatorResource("simulator.battery.discharging", "Discharging")
        }
    }

    func authorization(_ value: SimulatorPrivacyAuthorization) -> LocalizedStringResource {
        switch value {
        case .notDetermined: simulatorResource("simulator.authorization.notDetermined", "Not Determined")
        case .denied: simulatorResource("simulator.authorization.denied", "Denied")
        case .granted: simulatorResource("simulator.authorization.granted", "Granted")
        case .limited: simulatorResource("simulator.authorization.limited", "Limited")
        case .critical: simulatorResource("simulator.authorization.critical", "Critical Alerts")
        case .unknown: simulatorResource("simulator.authorization.unknown", "Unknown")
        }
    }

    func deviceState(_ state: SimulatorDeviceState) -> LocalizedStringResource {
        switch state {
        case .shutdown: simulatorResource("simulator.deviceState.shutdown", "Shut Down")
        case .booting: simulatorResource("simulator.deviceState.booting", "Booting")
        case .booted: simulatorResource("simulator.deviceState.booted", "Booted")
        case .shuttingDown: simulatorResource("simulator.deviceState.shuttingDown", "Shutting Down")
        case .unknown: simulatorResource("simulator.deviceState.unknown", "Unknown")
        }
    }

}

let simulatorStrings = SimulatorStrings()
