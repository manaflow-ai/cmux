import CmuxTerminalCore
import CoreFoundation
import Foundation
import IOKit
import IOKit.hid

/// Reads what decides which physical keys produce an agent key hint's
/// chord: Karabiner-Elements' `karabiner.json`, `hidutil`'s
/// `UserKeyMapping`, System Settings' per-keyboard modifier keys, and the
/// connected keyboards. Read only; it never changes any of them.
///
/// ``read()`` blocks on file, preference, registry, and process I/O, so it
/// runs on a background task, never on the hover path.
struct AgentKeyHintPhysicalKeyboardReader: Sendable {
    /// A file's modification date and size, to notice when it changes.
    struct FileStamp: Equatable, Sendable {
        var modificationDate: Date?
        var size: Int?
    }

    var karabinerURL: URL
    var application: KarabinerFrontmostApplication

    /// The user's Karabiner-Elements configuration and cmux itself.
    static var live: AgentKeyHintPhysicalKeyboardReader {
        AgentKeyHintPhysicalKeyboardReader(
            karabinerURL: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config/karabiner/karabiner.json", isDirectory: false),
            application: KarabinerFrontmostApplication(
                bundleIdentifier: Bundle.main.bundleIdentifier,
                executablePath: Bundle.main.executablePath
            )
        )
    }

    /// The stamp of `karabiner.json`; `nil` fields when it is missing.
    func karabinerStamp() -> FileStamp {
        let attributes = try? FileManager.default.attributesOfItem(atPath: karabinerURL.path)
        return FileStamp(
            modificationDate: attributes?[.modificationDate] as? Date,
            size: (attributes?[.size] as? NSNumber)?.intValue
        )
    }

    /// Reads every source. Blocking.
    ///
    /// - Returns: The setup, and the `karabiner.json` stamp taken before it
    ///   was read, so a save during the read is noticed on the next check.
    func read() -> (setup: PhysicalKeyboardSetup, karabinerStamp: FileStamp) {
        let stamp = karabinerStamp()
        // No file: Karabiner runs with no modifications. A file that can't be
        // read or parsed leaves Karabiner's remaps unknown (nil).
        let profile: KarabinerProfile?
        if stamp.modificationDate == nil {
            profile = .empty
        } else {
            profile = (try? Data(contentsOf: karabinerURL)).flatMap(KarabinerProfile.init(configurationData:))
        }
        let setup = PhysicalKeyboardSetup(
            connectedKeyboards: Self.connectedKeyboards(),
            karabiner: profile,
            userKeyMapping: HIDKeyMapping(hidutilOutput: Self.hidutilUserKeyMapping()),
            modifierKeys: SystemModifierKeyMappings(globalDomains: [
                Self.modifierMappingPreferences(host: kCFPreferencesAnyHost),
                Self.modifierMappingPreferences(host: kCFPreferencesCurrentHost),
            ]),
            application: application
        )
        return (setup, stamp)
    }

    /// Keyboards in the HID registry. Reads registry properties only; no
    /// device is opened, so this needs no Input Monitoring permission.
    static func connectedKeyboards() -> [KeyboardDevice] {
        guard let matching = IOServiceMatching(kIOHIDDeviceKey) as NSMutableDictionary? else { return [] }
        matching[kIOHIDDeviceUsagePageKey] = kHIDPage_GenericDesktop
        matching[kIOHIDDeviceUsageKey] = kHIDUsage_GD_Keyboard
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var keyboards: [KeyboardDevice] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            func property(_ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            // The Touch Bar and similar virtual devices aren't keyboards anyone
            // types on; a mouse's or combined device's extra keyboard
            // interface isn't a keyboard either, only a primary keyboard is.
            if property(kIOHIDTransportKey) as? String == "Virtual" { continue }
            guard (property(kIOHIDPrimaryUsagePageKey) as? NSNumber)?.intValue == Int(kHIDPage_GenericDesktop),
                  (property(kIOHIDPrimaryUsageKey) as? NSNumber)?.intValue == Int(kHIDUsage_GD_Keyboard) else { continue }
            keyboards.append(KeyboardDevice(
                name: property(kIOHIDProductKey) as? String ?? "",
                vendorID: (property(kIOHIDVendorIDKey) as? NSNumber)?.intValue ?? 0,
                productID: (property(kIOHIDProductIDKey) as? NSNumber)?.intValue ?? 0,
                isBuiltIn: (property(kIOHIDBuiltInKey) as? NSNumber)?.boolValue ?? false
            ))
        }
        return keyboards
    }

    /// `hidutil property --get UserKeyMapping` output, or `""` when it can't run.
    static func hidutilUserKeyMapping() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        process.arguments = ["property", "--get", "UserKeyMapping"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return ""
        }
        // The output is a few hundred bytes, well under the pipe buffer, so
        // reading to the end before waiting can't deadlock.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// The `com.apple.keyboard.modifiermapping.*` entries of the global
    /// preferences for `host`.
    static func modifierMappingPreferences(host: CFString) -> [String: Any] {
        let application = kCFPreferencesAnyApplication
        let user = kCFPreferencesCurrentUser
        guard let keys = CFPreferencesCopyKeyList(application, user, host) as? [String] else { return [:] }
        let wanted = keys.filter { $0.hasPrefix("com.apple.keyboard.modifiermapping.") }
        guard !wanted.isEmpty else { return [:] }
        return CFPreferencesCopyMultiple(wanted as CFArray, application, user, host) as? [String: Any] ?? [:]
    }
}
