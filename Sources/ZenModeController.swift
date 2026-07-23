import CmuxSettings
import Foundation

/// Owns the reversible settings ledger for the app-wide Zen Mode session.
@MainActor
final class ZenModeController {
    struct Session: Equatable {
        let windowID: UUID
        let restoresSidebarVisibility: Bool
        let exitsFullScreen: Bool
    }

    private static let recoveryActiveKey = "zenMode.recovery.active"
    private static let recoveryPresentationModeChangedKey = "zenMode.recovery.presentationModeChanged"
    private static let recoveryPresentationModeWasPresentKey = "zenMode.recovery.presentationModeWasPresent"
    private static let recoveryPresentationModeValueKey = "zenMode.recovery.presentationModeValue"
    private static let recoveryContentWidthChangedKey = "zenMode.recovery.contentWidthChanged"
    private static let recoveryContentWidthWasPresentKey = "zenMode.recovery.contentWidthWasPresent"
    private static let recoveryContentWidthValueKey = "zenMode.recovery.contentWidthValue"
    private static let recoveryAppliedContentWidthKey = "zenMode.recovery.appliedContentWidth"
    private static let recoverySidebarVisibilityChangedKey = "zenMode.recovery.sidebarVisibilityChanged"
    private static let recoveryWindowIDKey = "zenMode.recovery.windowID"

    private let defaults: UserDefaults
    private let contentWidthSettings: SessionContentWidthSettings
    private(set) var activeSession: Session?
    private var interruptedSidebarRecoveryWindowID: UUID?

    var isActive: Bool { activeSession != nil }

    init(
        defaults: UserDefaults = .standard,
        contentWidthSettings: SessionContentWidthSettings = SessionContentWidthSettings()
    ) {
        self.defaults = defaults
        self.contentWidthSettings = contentWidthSettings
        restoreInterruptedSettingsIfNeeded(captureSidebarRecovery: true)
    }

    /// Begins Zen Mode and records only state that must be restored later.
    func begin(
        windowID: UUID,
        isSidebarVisible: Bool,
        isFullScreen: Bool
    ) -> Session? {
        guard activeSession == nil else { return nil }

        let presentationModeChanged = !WorkspacePresentationModeSettings.isMinimal(defaults: defaults)
        let storedContentWidth = defaults.object(forKey: SessionContentWidthSettings.maxWidthKey)
            .flatMap { ($0 as? NSNumber)?.doubleValue }
            ?? SessionContentWidthSettings.noMaximumWidth
        let contentWidthChanged = contentWidthSettings.configuredMaximumWidth(from: storedContentWidth) == nil

        recordGlobalSettingsRecovery(
            windowID: windowID,
            presentationModeChanged: presentationModeChanged,
            contentWidthChanged: contentWidthChanged,
            sidebarVisibilityChanged: isSidebarVisible
        )

        if presentationModeChanged {
            defaults.set(
                WorkspacePresentationModeSettings.Mode.minimal.rawValue,
                forKey: WorkspacePresentationModeSettings.modeKey
            )
        }

        if contentWidthChanged {
            let rememberedWidth = defaults.object(forKey: SessionContentWidthSettings.rememberedMaxWidthKey)
                .flatMap { ($0 as? NSNumber)?.doubleValue }
                ?? SessionContentWidthSettings.defaultConfiguredMaximumWidth
            let zenWidth = contentWidthSettings.editorMaximumWidth(
                activeStoredValue: storedContentWidth,
                rememberedStoredValue: rememberedWidth
            )
            defaults.set(zenWidth, forKey: SessionContentWidthSettings.maxWidthKey)
            defaults.set(zenWidth, forKey: Self.recoveryAppliedContentWidthKey)
        }

        let session = Session(
            windowID: windowID,
            restoresSidebarVisibility: isSidebarVisible,
            exitsFullScreen: !isFullScreen
        )
        activeSession = session
        return session
    }

    /// Ends Zen Mode and restores global settings that still have Zen's values.
    func end() -> Session? {
        guard let activeSession else { return nil }
        restoreInterruptedSettingsIfNeeded(captureSidebarRecovery: false)
        self.activeSession = nil
        return activeSession
    }

    /// Ends Zen Mode when its target window closes.
    func endIfTargeting(windowID: UUID) -> Session? {
        guard activeSession?.windowID == windowID else { return nil }
        return end()
    }

    /// Restores temporary global settings before normal application termination.
    func restoreForTermination() -> Session? {
        end()
    }

    /// Consumes crash recovery after session restoration has recreated the target window.
    func consumeInterruptedSidebarVisibilityRecovery(windowID: UUID) -> Bool {
        guard interruptedSidebarRecoveryWindowID == windowID else { return false }
        interruptedSidebarRecoveryWindowID = nil
        defaults.removeObject(forKey: Self.recoverySidebarVisibilityChangedKey)
        defaults.removeObject(forKey: Self.recoveryWindowIDKey)
        return true
    }

    private func recordGlobalSettingsRecovery(
        windowID: UUID,
        presentationModeChanged: Bool,
        contentWidthChanged: Bool,
        sidebarVisibilityChanged: Bool
    ) {
        guard presentationModeChanged || contentWidthChanged || sidebarVisibilityChanged else { return }

        defaults.set(true, forKey: Self.recoveryActiveKey)
        defaults.set(presentationModeChanged, forKey: Self.recoveryPresentationModeChangedKey)
        defaults.set(contentWidthChanged, forKey: Self.recoveryContentWidthChangedKey)
        defaults.set(sidebarVisibilityChanged, forKey: Self.recoverySidebarVisibilityChangedKey)
        if sidebarVisibilityChanged {
            defaults.set(windowID.uuidString, forKey: Self.recoveryWindowIDKey)
        }

        if presentationModeChanged {
            let previousValue = defaults.string(forKey: WorkspacePresentationModeSettings.modeKey)
            defaults.set(previousValue != nil, forKey: Self.recoveryPresentationModeWasPresentKey)
            if let previousValue {
                defaults.set(previousValue, forKey: Self.recoveryPresentationModeValueKey)
            }
        }

        if contentWidthChanged {
            let previousValue = defaults.object(forKey: SessionContentWidthSettings.maxWidthKey)
                .flatMap { ($0 as? NSNumber)?.doubleValue }
            defaults.set(previousValue != nil, forKey: Self.recoveryContentWidthWasPresentKey)
            if let previousValue {
                defaults.set(previousValue, forKey: Self.recoveryContentWidthValueKey)
            }
        }
    }

    private func restoreInterruptedSettingsIfNeeded(captureSidebarRecovery: Bool) {
        var capturedSidebarRecovery = false
        if captureSidebarRecovery,
           defaults.bool(forKey: Self.recoverySidebarVisibilityChangedKey),
           let rawWindowID = defaults.string(forKey: Self.recoveryWindowIDKey),
           let windowID = UUID(uuidString: rawWindowID) {
            interruptedSidebarRecoveryWindowID = windowID
            capturedSidebarRecovery = true
        }

        guard defaults.bool(forKey: Self.recoveryActiveKey) else { return }

        if defaults.bool(forKey: Self.recoveryPresentationModeChangedKey),
           WorkspacePresentationModeSettings.isMinimal(defaults: defaults) {
            restorePreviousValue(
                key: WorkspacePresentationModeSettings.modeKey,
                wasPresentKey: Self.recoveryPresentationModeWasPresentKey,
                valueKey: Self.recoveryPresentationModeValueKey
            )
        }

        if defaults.bool(forKey: Self.recoveryContentWidthChangedKey),
           let currentWidth = defaults.object(forKey: SessionContentWidthSettings.maxWidthKey)
               .flatMap({ ($0 as? NSNumber)?.doubleValue }),
           currentWidth == defaults.double(forKey: Self.recoveryAppliedContentWidthKey) {
            if defaults.bool(forKey: Self.recoveryContentWidthWasPresentKey) {
                defaults.set(
                    defaults.double(forKey: Self.recoveryContentWidthValueKey),
                    forKey: SessionContentWidthSettings.maxWidthKey
                )
            } else {
                defaults.removeObject(forKey: SessionContentWidthSettings.maxWidthKey)
            }
        }

        clearRecoveryState(preservingSidebarRecovery: capturedSidebarRecovery)
    }

    private func restorePreviousValue(key: String, wasPresentKey: String, valueKey: String) {
        if defaults.bool(forKey: wasPresentKey), let previousValue = defaults.string(forKey: valueKey) {
            defaults.set(previousValue, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private func clearRecoveryState(preservingSidebarRecovery: Bool = false) {
        var keys = [
            Self.recoveryActiveKey,
            Self.recoveryPresentationModeChangedKey,
            Self.recoveryPresentationModeWasPresentKey,
            Self.recoveryPresentationModeValueKey,
            Self.recoveryContentWidthChangedKey,
            Self.recoveryContentWidthWasPresentKey,
            Self.recoveryContentWidthValueKey,
            Self.recoveryAppliedContentWidthKey,
        ]
        if !preservingSidebarRecovery {
            keys.append(Self.recoverySidebarVisibilityChangedKey)
            keys.append(Self.recoveryWindowIDKey)
        }
        keys.forEach(defaults.removeObject(forKey:))
    }
}
