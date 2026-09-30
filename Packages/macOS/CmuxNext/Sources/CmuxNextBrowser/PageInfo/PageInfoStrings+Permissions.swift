import Foundation

/// Permission names and Chrome's "Can ask to …" texts.
extension PageInfoStrings {
    static func name(_ kind: SitePermissionKind) -> String {
        switch kind {
        case .location: String(localized: "pageInfo.permission.location", defaultValue: "Location", table: "PageInfo", bundle: .module)
        case .camera: String(localized: "pageInfo.permission.camera", defaultValue: "Camera", table: "PageInfo", bundle: .module)
        case .microphone: String(localized: "pageInfo.permission.microphone", defaultValue: "Microphone", table: "PageInfo", bundle: .module)
        case .notifications: String(localized: "pageInfo.permission.notifications", defaultValue: "Notifications", table: "PageInfo", bundle: .module)
        case .javascript: String(localized: "pageInfo.permission.javascript", defaultValue: "JavaScript", table: "PageInfo", bundle: .module)
        case .images: String(localized: "pageInfo.permission.images", defaultValue: "Images", table: "PageInfo", bundle: .module)
        case .popups: String(localized: "pageInfo.permission.popups", defaultValue: "Pop-ups and redirects", table: "PageInfo", bundle: .module)
        case .sound: String(localized: "pageInfo.permission.sound", defaultValue: "Sound", table: "PageInfo", bundle: .module)
        case .automaticDownloads: String(localized: "pageInfo.permission.automaticDownloads", defaultValue: "Automatic downloads", table: "PageInfo", bundle: .module)
        case .midi: String(localized: "pageInfo.permission.midi", defaultValue: "MIDI device control & reprogram", table: "PageInfo", bundle: .module)
        case .usb: String(localized: "pageInfo.permission.usb", defaultValue: "USB devices", table: "PageInfo", bundle: .module)
        case .serial: String(localized: "pageInfo.permission.serial", defaultValue: "Serial ports", table: "PageInfo", bundle: .module)
        case .hid: String(localized: "pageInfo.permission.hid", defaultValue: "HID devices", table: "PageInfo", bundle: .module)
        case .clipboard: String(localized: "pageInfo.permission.clipboard", defaultValue: "Clipboard", table: "PageInfo", bundle: .module)
        case .sensors: String(localized: "pageInfo.permission.sensors", defaultValue: "Motion sensors", table: "PageInfo", bundle: .module)
        case .bluetooth: String(localized: "pageInfo.permission.bluetooth", defaultValue: "Bluetooth devices", table: "PageInfo", bundle: .module)
        case .fileEditing: String(localized: "pageInfo.permission.fileEditing", defaultValue: "File editing", table: "PageInfo", bundle: .module)
        case .windowManagement: String(localized: "pageInfo.permission.windowManagement", defaultValue: "Window management", table: "PageInfo", bundle: .module)
        case .localFonts: String(localized: "pageInfo.permission.localFonts", defaultValue: "Fonts", table: "PageInfo", bundle: .module)
        case .backgroundSync: String(localized: "pageInfo.permission.backgroundSync", defaultValue: "Background sync", table: "PageInfo", bundle: .module)
        case .autoPictureInPicture: String(localized: "pageInfo.permission.autoPictureInPicture", defaultValue: "Auto picture-in-picture", table: "PageInfo", bundle: .module)
        case .thirdPartySignIn: String(localized: "pageInfo.permission.thirdPartySignIn", defaultValue: "Third-party sign-in", table: "PageInfo", bundle: .module)
        case .insecureContent: String(localized: "pageInfo.permission.insecureContent", defaultValue: "Insecure content", table: "PageInfo", bundle: .module)
        }
    }

    /// Chrome's "Can ask to …" state text for a permission at its ask default.
    static func askText(_ kind: SitePermissionKind) -> String? {
        switch kind {
        case .location: String(localized: "pageInfo.ask.location", defaultValue: "Can ask for your location", table: "PageInfo", bundle: .module)
        case .camera: String(localized: "pageInfo.ask.camera", defaultValue: "Can ask to use your camera", table: "PageInfo", bundle: .module)
        case .microphone: String(localized: "pageInfo.ask.microphone", defaultValue: "Can ask to use your microphone", table: "PageInfo", bundle: .module)
        case .notifications: String(localized: "pageInfo.ask.notifications", defaultValue: "Can ask to send notifications", table: "PageInfo", bundle: .module)
        case .automaticDownloads: String(localized: "pageInfo.ask.automaticDownloads", defaultValue: "Can ask to automatically download multiple files", table: "PageInfo", bundle: .module)
        case .midi: String(localized: "pageInfo.ask.midi", defaultValue: "Can ask to control and reprogram your MIDI devices", table: "PageInfo", bundle: .module)
        case .usb: String(localized: "pageInfo.ask.usb", defaultValue: "Can ask to connect to USB devices", table: "PageInfo", bundle: .module)
        case .serial: String(localized: "pageInfo.ask.serial", defaultValue: "Can ask to connect to serial ports", table: "PageInfo", bundle: .module)
        case .hid: String(localized: "pageInfo.ask.hid", defaultValue: "Can ask to connect to HID devices", table: "PageInfo", bundle: .module)
        case .clipboard: String(localized: "pageInfo.ask.clipboard", defaultValue: "Can ask to see text and images on your clipboard", table: "PageInfo", bundle: .module)
        case .bluetooth: String(localized: "pageInfo.ask.bluetooth", defaultValue: "Can ask to connect to Bluetooth devices", table: "PageInfo", bundle: .module)
        case .fileEditing: String(localized: "pageInfo.ask.fileEditing", defaultValue: "Can ask to edit files and folders on your device", table: "PageInfo", bundle: .module)
        case .windowManagement: String(localized: "pageInfo.ask.windowManagement", defaultValue: "Can ask to manage windows on all your displays", table: "PageInfo", bundle: .module)
        case .localFonts: String(localized: "pageInfo.ask.localFonts", defaultValue: "Can ask to use fonts installed on your device", table: "PageInfo", bundle: .module)
        case .autoPictureInPicture: String(localized: "pageInfo.ask.autoPictureInPicture", defaultValue: "Can ask to enter picture-in-picture automatically", table: "PageInfo", bundle: .module)
        case .javascript, .images, .popups, .sound, .sensors, .backgroundSync, .thirdPartySignIn, .insecureContent: nil
        }
    }
}
