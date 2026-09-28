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
struct AgentKeyHintPhysicalKeyboardReader: AgentKeyHintPhysicalKeyboardReading {
    var karabinerURL: URL
    var application: KarabinerFrontmostApplication
    /// How long `hidutil` may run before it is stopped and its mapping
    /// counts as unknown.
    var hidutilTimeout: TimeInterval = 2

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
    func karabinerStamp() -> AgentKeyHintFileStamp {
        let attributes = try? FileManager.default.attributesOfItem(atPath: karabinerURL.path)
        return AgentKeyHintFileStamp(
            modificationDate: attributes?[.modificationDate] as? Date,
            size: (attributes?[.size] as? NSNumber)?.intValue
        )
    }

    /// Reads every source. Blocking, for at most about ``hidutilTimeout``.
    func read() -> (setup: PhysicalKeyboardSetup, karabinerStamp: AgentKeyHintFileStamp) {
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
            userKeyMapping: Self.runForOutput(
                URL(fileURLWithPath: "/usr/bin/hidutil"),
                arguments: ["property", "--get", "UserKeyMapping"],
                timeout: hidutilTimeout
            ).map(HIDKeyMapping.init(hidutilOutput:)),
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

    /// A command's standard output, or `nil` when it can't start, exits
    /// with a failure, or runs past `timeout` (it is then terminated). Used
    /// for `hidutil property --get UserKeyMapping`.
    static func runForOutput(_ executable: URL, arguments: [String], timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        // A bounded wait for the process to exit on this background task,
        // not a lock: the semaphore is signaled once, by the termination handler.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }
        guard exited.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            return nil
        }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { return nil }
        // hidutil prints a few hundred bytes, well under the pipe buffer, so
        // it can exit before its output is read.
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
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
