import AppKit
import OSLog
import SwiftUI
import os

private struct UIScalePendingPersistence: Sendable {
    let identifier: String
    let value: Double
    let defaultsIdentity: UInt
}

private nonisolated let uiScalePendingPersistence = OSAllocatedUnfairLock(
    initialState: UIScalePendingPersistence?.none
)

enum UIScaleSettings {
    static let userDefaultsKey = "app.uiScale"
    static let jsonPath = "app.uiScale"
    static let didChangeNotification = Notification.Name("cmux.uiScaleDidChange")
    static let defaultValue = 1.0
    static let minimum = 0.7
    static let maximum = 2.0
    static let keyboardStep = 0.1
    private static let logger = Logger(subsystem: "ai.manaflow.cmux", category: "UIScaleSettings")
    private static let persistenceCoordinator = UIScaleSettingsPersistenceCoordinator()

    static func clamped(_ value: Double) -> Double {
        min(max(value, minimum), maximum)
    }

    static func resolved(defaults: UserDefaults = .standard) -> Double {
        guard let number = defaults.object(forKey: userDefaultsKey) as? NSNumber else {
            return defaultValue
        }
        return clamped(number.doubleValue)
    }

    @discardableResult
    @MainActor
    static func set(
        _ value: Double,
        defaults: UserDefaults = .standard,
        settingsFileStore: CmuxSettingsFileStore? = nil,
        persistToSettingsFile: Bool = true,
        notificationCenter: NotificationCenter = .default
    ) -> Double {
        let next = roundedForPersistence(clamped(value))
        defaults.set(next, forKey: userDefaultsKey)
        if persistToSettingsFile {
            let requestIdentifier = UUID().uuidString
            let store = settingsFileStore ?? KeyboardShortcutSettings.settingsFileStore
            let defaultsHandle = UIScaleSettingsDefaultsHandle(defaults: defaults)
            recordPendingPersistence(value: next, identifier: requestIdentifier, defaults: defaults)
            Task {
                await persistenceCoordinator.schedule(
                    value: next,
                    identifier: requestIdentifier,
                    defaults: defaultsHandle,
                    settingsFileStore: store
                )
            }
        } else {
            clearPendingPersistence(defaults: defaults)
            Task {
                await persistenceCoordinator.cancel()
            }
        }
        notificationCenter.post(name: didChangeNotification, object: nil, userInfo: ["value": next])
        return next
    }

    @discardableResult
    @MainActor
    static func zoomIn() -> Double {
        set(resolved() + keyboardStep)
    }

    @discardableResult
    @MainActor
    static func zoomOut() -> Double {
        set(resolved() - keyboardStep)
    }

    @discardableResult
    @MainActor
    static func reset() -> Double {
        set(defaultValue)
    }

    static func scaled(_ value: CGFloat, by uiScaleFactor: Double) -> CGFloat {
        value * CGFloat(clamped(uiScaleFactor))
    }

    static func roundedForPersistence(_ value: Double) -> Double {
        (clamped(value) * 100).rounded() / 100
    }

    static func settingsFileManagedValue(
        _ value: Double,
        defaults: UserDefaults = .standard
    ) -> Double {
        let persisted = roundedForPersistence(value)
        let current = roundedForPersistence(resolved(defaults: defaults))
        guard let pending = pendingPersistence(defaults: defaults) else {
            return persisted
        }
        if roundedForPersistence(pending.value) == current && persisted != current {
            return current
        }
        return persisted
    }

    fileprivate static func completePendingPersistence(
        identifier: String,
        defaults: UserDefaults,
        settingsFileStore: CmuxSettingsFileStore
    ) {
        guard isPendingPersistenceCurrent(identifier: identifier, defaults: defaults) else {
            return
        }
        clearPendingPersistence(defaults: defaults)
        settingsFileStore.reload()
    }

    fileprivate static func failPendingPersistence(
        identifier: String,
        defaults: UserDefaults,
        error: Error
    ) {
        if isPendingPersistenceCurrent(identifier: identifier, defaults: defaults) {
            clearPendingPersistence(defaults: defaults)
        }
        logger.error(
            "Failed to persist \(jsonPath, privacy: .public): \(String(describing: error), privacy: .public)"
        )
    }

    fileprivate static func isPendingPersistenceCurrent(
        identifier: String,
        defaults: UserDefaults
    ) -> Bool {
        pendingPersistence(defaults: defaults)?.identifier == identifier
    }

    private static func recordPendingPersistence(
        value: Double,
        identifier: String,
        defaults: UserDefaults
    ) {
        uiScalePendingPersistence.withLock { pending in
            pending = UIScalePendingPersistence(
                identifier: identifier,
                value: roundedForPersistence(value),
                defaultsIdentity: defaultsIdentity(defaults)
            )
        }
    }

    private static func pendingPersistence(defaults: UserDefaults) -> (identifier: String, value: Double)? {
        let identity = defaultsIdentity(defaults)
        guard let pending = uiScalePendingPersistence.withLock({ $0 }),
              pending.defaultsIdentity == identity else {
            return nil
        }
        return (pending.identifier, pending.value)
    }

    private static func clearPendingPersistence(defaults: UserDefaults) {
        let identity = defaultsIdentity(defaults)
        uiScalePendingPersistence.withLock { pending in
            guard pending?.defaultsIdentity == identity else { return }
            pending = nil
        }
    }

    private static func defaultsIdentity(_ defaults: UserDefaults) -> UInt {
        UInt(bitPattern: Unmanaged.passUnretained(defaults).toOpaque())
    }
}

// Sendable safety: UserDefaults is the existing synchronized storage boundary for
// volatile pending-write state. The handle is only dereferenced from main-actor
// coordination closures while the persistence actor owns debounce cancellation.
private struct UIScaleSettingsDefaultsHandle: @unchecked Sendable {
    let defaults: UserDefaults
}

private actor UIScaleSettingsPersistenceCoordinator {
    private static let debounceDuration: Duration = .milliseconds(150)

    private var pendingTask: Task<Void, Never>?

    func schedule(
        value: Double,
        identifier: String,
        defaults: UIScaleSettingsDefaultsHandle,
        settingsFileStore: CmuxSettingsFileStore
    ) async {
        let isCurrent = await MainActor.run {
            UIScaleSettings.isPendingPersistenceCurrent(
                identifier: identifier,
                defaults: defaults.defaults
            )
        }
        guard isCurrent else { return }
        pendingTask?.cancel()
        pendingTask = Task {
            do {
                try await Task.sleep(for: Self.debounceDuration)
                try Task.checkCancellation()
                let shouldWrite = await MainActor.run {
                    UIScaleSettings.isPendingPersistenceCurrent(
                        identifier: identifier,
                        defaults: defaults.defaults
                    )
                }
                guard shouldWrite else { return }
                try await settingsFileStore.writeAppUIScaleOffMain(value)
                try Task.checkCancellation()
                await MainActor.run {
                    UIScaleSettings.completePendingPersistence(
                        identifier: identifier,
                        defaults: defaults.defaults,
                        settingsFileStore: settingsFileStore
                    )
                }
            } catch is CancellationError {
            } catch {
                await MainActor.run {
                    UIScaleSettings.failPendingPersistence(
                        identifier: identifier,
                        defaults: defaults.defaults,
                        error: error
                    )
                }
            }
        }
    }

    func cancel() {
        pendingTask?.cancel()
        pendingTask = nil
    }
}

private struct UIScaleFactorEnvironmentKey: EnvironmentKey {
    static let defaultValue = UIScaleSettings.defaultValue
}

extension EnvironmentValues {
    var uiScaleFactor: Double {
        get { self[UIScaleFactorEnvironmentKey.self] }
        set { self[UIScaleFactorEnvironmentKey.self] = UIScaleSettings.clamped(newValue) }
    }
}

private struct UIScaledFontModifier: ViewModifier {
    @Environment(\.uiScaleFactor) private var uiScaleFactor

    let size: CGFloat
    let weight: Font.Weight?
    let design: Font.Design?

    func body(content: Content) -> some View {
        content.font(
            .system(
                size: UIScaleSettings.scaled(size, by: uiScaleFactor),
                weight: weight,
                design: design
            )
        )
    }
}

private struct UIScaledTextStyleFontModifier: ViewModifier {
    @Environment(\.uiScaleFactor) private var uiScaleFactor
    @ScaledMetric private var textStyleSize: CGFloat

    let weight: Font.Weight?
    let design: Font.Design?

    init(
        size: CGFloat,
        weight: Font.Weight?,
        design: Font.Design?,
        relativeTo textStyle: Font.TextStyle
    ) {
        _textStyleSize = ScaledMetric(wrappedValue: size, relativeTo: textStyle)
        self.weight = weight
        self.design = design
    }

    func body(content: Content) -> some View {
        content.font(
            .system(
                size: UIScaleSettings.scaled(textStyleSize, by: uiScaleFactor),
                weight: weight,
                design: design
            )
        )
    }
}

extension View {
    func cmuxFont(size: CGFloat, weight: Font.Weight? = nil, design: Font.Design? = nil) -> some View {
        modifier(UIScaledFontModifier(size: size, weight: weight, design: design))
    }

    func cmuxFont(
        size: CGFloat,
        weight: Font.Weight? = nil,
        design: Font.Design? = nil,
        relativeTo textStyle: Font.TextStyle
    ) -> some View {
        modifier(
            UIScaledTextStyleFontModifier(
                size: size,
                weight: weight,
                design: design,
                relativeTo: textStyle
            )
        )
    }
}

extension NSFont {
    static func cmuxSystemFont(ofSize size: CGFloat, weight: NSFont.Weight = .regular, uiScaleFactor: Double) -> NSFont {
        systemFont(ofSize: UIScaleSettings.scaled(size, by: uiScaleFactor), weight: weight)
    }

    static func cmuxMonospacedSystemFont(
        ofSize size: CGFloat,
        weight: NSFont.Weight = .regular,
        uiScaleFactor: Double
    ) -> NSFont {
        monospacedSystemFont(ofSize: UIScaleSettings.scaled(size, by: uiScaleFactor), weight: weight)
    }
}
