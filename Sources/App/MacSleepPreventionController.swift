import AppKit
import Foundation
import IOKit.pwr_mgt

@MainActor
protocol MacSleepPreventionControlling: AnyObject {
    var isEnabled: Bool { get }
    var lastError: IOReturn? { get }
    func syncToSettings()
    @discardableResult func setEnabled(_ enabled: Bool) -> Bool
}

@MainActor
protocol MacScreenLocking: AnyObject {
    var lastErrorDescription: String? { get }
    @discardableResult func lockScreen() -> Bool
}

@MainActor
final class MacSleepPreventionController: MacSleepPreventionControlling {
    enum AssertionAcquireResult {
        case success(IOPMAssertionID)
        case failure(IOReturn)
    }

    typealias AssertionAcquire = (_ reason: String) -> AssertionAcquireResult
    typealias AssertionRelease = (_ assertionID: IOPMAssertionID) -> IOReturn

    static let shared = MacSleepPreventionController()

    private let defaults: UserDefaults
    private let acquireAssertion: AssertionAcquire
    private let releaseAssertion: AssertionRelease
    private var assertionID: IOPMAssertionID?
    private(set) var lastError: IOReturn?

    var isEnabled: Bool {
        assertionID != nil
    }

    init(
        defaults: UserDefaults = .standard,
        acquireAssertion: @escaping AssertionAcquire = MacSleepPreventionController.acquireSystemSleepAssertion,
        releaseAssertion: @escaping AssertionRelease = IOPMAssertionRelease
    ) {
        self.defaults = defaults
        self.acquireAssertion = acquireAssertion
        self.releaseAssertion = releaseAssertion
    }

    deinit {
        if let assertionID {
            _ = releaseAssertion(assertionID)
        }
    }

    func syncToSettings() {
        apply(enabled: MacSleepPreventionSettings.isEnabled(defaults: defaults), persist: false)
    }

    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        apply(enabled: enabled, persist: true)
    }

    @discardableResult
    private func apply(enabled: Bool, persist: Bool) -> Bool {
        if enabled {
            guard assertionID == nil else {
                if persist { MacSleepPreventionSettings.setEnabled(true, defaults: defaults) }
                return true
            }

            switch acquireAssertion(String(localized: "sleepPrevention.assertion.reason", defaultValue: "cmux Prevent System Sleep")) {
            case .success(let assertionID):
                self.assertionID = assertionID
                lastError = nil
                if persist { MacSleepPreventionSettings.setEnabled(true, defaults: defaults) }
                return true
            case .failure(let error):
                lastError = error
                if persist { MacSleepPreventionSettings.setEnabled(false, defaults: defaults) }
                return false
            }
        }

        releaseActiveAssertion()
        lastError = nil
        if persist { MacSleepPreventionSettings.setEnabled(false, defaults: defaults) }
        return true
    }

    private func releaseActiveAssertion() {
        guard let assertionID else { return }
        _ = releaseAssertion(assertionID)
        self.assertionID = nil
    }

    nonisolated private static func acquireSystemSleepAssertion(reason: String) -> AssertionAcquireResult {
        var assertionID = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoIdleSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &assertionID
        )
        guard result == kIOReturnSuccess else {
            return .failure(result)
        }
        return .success(assertionID)
    }
}

@MainActor
final class MacScreenLocker: MacScreenLocking {
    typealias RunLockCommand = () throws -> Void

    static let shared = MacScreenLocker()
    nonisolated static let lockExecutablePath = "/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession"
    nonisolated static let lockArguments = ["-suspend"]

    private let runLockCommand: RunLockCommand
    private(set) var lastErrorDescription: String?

    init(runLockCommand: @escaping RunLockCommand = MacScreenLocker.runSystemLockCommand) {
        self.runLockCommand = runLockCommand
    }

    @discardableResult
    func lockScreen() -> Bool {
        do {
            try runLockCommand()
            lastErrorDescription = nil
            return true
        } catch {
            lastErrorDescription = error.localizedDescription
            return false
        }
    }

    nonisolated private static func runSystemLockCommand() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: lockExecutablePath)
        process.arguments = lockArguments
        try process.run()
    }
}

@MainActor
enum MacSleepPreventionActions {
    @discardableResult
    static func lockScreenAndPreventSleep(
        sleepPreventionController: MacSleepPreventionControlling,
        screenLocker: MacScreenLocking
    ) -> Bool {
        let wasEnabled = sleepPreventionController.isEnabled
        guard sleepPreventionController.setEnabled(true) else {
            return false
        }

        guard screenLocker.lockScreen() else {
            if !wasEnabled {
                _ = sleepPreventionController.setEnabled(false)
            }
            return false
        }

        return true
    }

    @discardableResult
    static func lockScreenAndPreventSleep() -> Bool {
        lockScreenAndPreventSleep(
            sleepPreventionController: MacSleepPreventionController.shared,
            screenLocker: MacScreenLocker.shared
        )
    }
}

enum MacSleepPreventionSettings {
    static let preventSystemSleepKey = "preventSystemSleep"
    static let defaultPreventSystemSleep = false

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: preventSystemSleepKey) == nil {
            return defaultPreventSystemSleep
        }
        return defaults.bool(forKey: preventSystemSleepKey)
    }

    static func setEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: preventSystemSleepKey)
    }
}

extension MenuBarExtraController {
    func addSleepPreventionMenuItems() {
        preventSystemSleepItem.target = self
        preventSystemSleepItem.action = #selector(togglePreventSystemSleepAction)
        preventSystemSleepItem.toolTip = String(
            localized: "statusMenu.preventSystemSleep.tooltip",
            defaultValue: "Keep the Mac awake while cmux is running."
        )
        menu.addItem(preventSystemSleepItem)

        let lockItem = NSMenuItem(
            title: String(
                localized: "statusMenu.lockScreenAndPreventSleep",
                defaultValue: "Lock Screen and Prevent Sleep"
            ),
            action: #selector(lockScreenAndPreventSleepAction),
            keyEquivalent: ""
        )
        lockItem.target = self
        lockItem.toolTip = String(
            localized: "statusMenu.lockScreenAndPreventSleep.tooltip",
            defaultValue: "Turn on Prevent System Sleep, then lock the Mac."
        )
        menu.addItem(lockItem)
    }

    @objc func togglePreventSystemSleepAction() {
        let nextValue = !sleepPreventionController.isEnabled
        if !sleepPreventionController.setEnabled(nextValue) {
            NSSound.beep()
        }
        refreshForDebugControls()
    }

    @objc func lockScreenAndPreventSleepAction() {
        if !MacSleepPreventionActions.lockScreenAndPreventSleep(
            sleepPreventionController: sleepPreventionController,
            screenLocker: MacScreenLocker.shared
        ) {
            NSSound.beep()
        }
        refreshForDebugControls()
    }
}

extension ContentView {
    static func commandPaletteSleepPreventionCommandContributions() -> [CommandPaletteCommandContribution] {
        [
            CommandPaletteCommandContribution(
                commandId: "palette.lockScreenAndPreventSleep",
                title: { _ in String(localized: "command.lockScreenAndPreventSleep.title", defaultValue: "Lock Screen and Prevent Sleep") },
                subtitle: { _ in String(localized: "command.lockScreenAndPreventSleep.subtitle", defaultValue: "Power") },
                keywords: ["lock", "screen", "sleep", "awake", "prevent", "never", "caffeinate", "power", "menu", "bar"]
            ),
        ]
    }

    static func commandPaletteSleepPreventionAndSettingsCommandContributions() -> [CommandPaletteCommandContribution] {
        commandPaletteSleepPreventionCommandContributions() + commandPaletteSettingsToggleCommandContributions()
    }

    func registerSleepPreventionCommandHandlers(_ registry: inout CommandPaletteHandlerRegistry) {
        registry.register(commandId: "palette.lockScreenAndPreventSleep") {
            if !MacSleepPreventionActions.lockScreenAndPreventSleep() {
                NSSound.beep()
            }
        }
    }

    func registerSleepPreventionAndSettingsCommandHandlers(_ registry: inout CommandPaletteHandlerRegistry) {
        registerSleepPreventionCommandHandlers(&registry)
        registerSettingsToggleCommandHandlers(&registry)
    }
}
