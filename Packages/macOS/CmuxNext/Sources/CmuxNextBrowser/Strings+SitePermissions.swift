import Foundation

/// The prompt bar's question for Chromium's other requests: "<origin> wants to" over one line per item, as Chrome's
/// permission bubble shows them (`IDS_PERMISSIONS_BUBBLE_PROMPT` and
/// `permissions::GetMessageTextFragment`).
extension Strings {
    static func permissionCapabilities(_ origin: String, _ items: [BrowserSiteCapability]) -> String {
        let title = String(localized: "browser.permission.wantsTo", defaultValue: "\(origin) wants to", bundle: .module)
        return ([title] + items.map { "• " + capability($0) }).joined(separator: "\n")
    }

    static func capability(_ item: BrowserSiteCapability) -> String {
        switch item {
        case .arSession:
            String(localized: "browser.permission.item.arSession", defaultValue: "Create a 3D map of your surroundings and track camera position", bundle: .module)
        case .cameraPanTiltZoom:
            String(localized: "browser.permission.item.cameraPanTiltZoom", defaultValue: "Use and move your cameras", bundle: .module)
        case .camera:
            String(localized: "browser.permission.item.camera", defaultValue: "Use your cameras", bundle: .module)
        case .capturedSurfaceControl:
            String(localized: "browser.permission.item.capturedSurfaceControl", defaultValue: "Scroll and zoom shared tabs", bundle: .module)
        case .clipboard:
            String(localized: "browser.permission.item.clipboard", defaultValue: "See text and images copied to the clipboard", bundle: .module)
        case .topLevelStorageAccess, .storageAccess:
            String(localized: "browser.permission.item.storageAccess", defaultValue: "Use cookies and site data it saved on other sites", bundle: .module)
        case .diskQuota:
            String(localized: "browser.permission.item.diskQuota", defaultValue: "Store files on this device", bundle: .module)
        case .localFonts:
            String(localized: "browser.permission.item.localFonts", defaultValue: "Use the fonts installed on your device", bundle: .module)
        case .location:
            String(localized: "browser.permission.item.location", defaultValue: "Know your location", bundle: .module)
        case .handTracking:
            String(localized: "browser.permission.item.handTracking", defaultValue: "Track your hands", bundle: .module)
        case .identityProvider:
            String(localized: "browser.permission.item.identityProvider", defaultValue: "Sign you in with your accounts on other sites", bundle: .module)
        case .idleDetection:
            String(localized: "browser.permission.item.idleDetection", defaultValue: "Know when you’re actively using this device", bundle: .module)
        case .microphone:
            String(localized: "browser.permission.item.microphone", defaultValue: "Use your microphones", bundle: .module)
        case .midiSysex:
            String(localized: "browser.permission.item.midiSysex", defaultValue: "Control and reprogram your MIDI devices", bundle: .module)
        case .multipleDownloads:
            String(localized: "browser.permission.item.multipleDownloads", defaultValue: "Download multiple files", bundle: .module)
        case .notifications:
            String(localized: "browser.permission.item.notifications", defaultValue: "Show notifications", bundle: .module)
        case .keyboardLock:
            String(localized: "browser.permission.item.keyboardLock", defaultValue: "Capture and use your keyboard", bundle: .module)
        case .pointerLock:
            String(localized: "browser.permission.item.pointerLock", defaultValue: "Lock and use your mouse", bundle: .module)
        case .protectedMediaIdentifier:
            String(localized: "browser.permission.item.protectedMediaIdentifier", defaultValue: "Know your unique device identifier to play protected content", bundle: .module)
        case .registerProtocolHandler:
            String(localized: "browser.permission.item.registerProtocolHandler", defaultValue: "Open a type of link", bundle: .module)
        case .vrSession:
            String(localized: "browser.permission.item.vrSession", defaultValue: "Use your virtual reality devices and data", bundle: .module)
        case .webAppInstallation:
            String(localized: "browser.permission.item.webAppInstallation", defaultValue: "Install web apps", bundle: .module)
        case .windowManagement:
            String(localized: "browser.permission.item.windowManagement", defaultValue: "Manage windows on all your displays", bundle: .module)
        case .fileSystemAccess:
            String(localized: "browser.permission.item.fileSystemAccess", defaultValue: "Edit files and folders on your device", bundle: .module)
        case .localNetwork:
            String(localized: "browser.permission.item.localNetwork", defaultValue: "Look for and connect to any device on your local network", bundle: .module)
        case .loopbackNetwork:
            String(localized: "browser.permission.item.loopbackNetwork", defaultValue: "Access other apps and services on this device", bundle: .module)
        case .sensors:
            String(localized: "browser.permission.item.sensors", defaultValue: "Use your device’s motion sensors", bundle: .module)
        }
    }
}
