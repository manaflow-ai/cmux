import AppKit
import OSLog
import SwiftUI

enum UIScaleSettings {
    static let userDefaultsKey = "app.uiScale"
    static let jsonPath = "app.uiScale"
    static let didChangeNotification = Notification.Name("cmux.uiScaleDidChange")
    static let defaultValue = 1.0
    static let minimum = 0.7
    static let maximum = 2.0
    static let keyboardStep = 0.1
    private static let logger = Logger(subsystem: "ai.manaflow.cmux", category: "UIScaleSettings")
    private static let persistenceQueue = DispatchQueue(label: "ai.manaflow.cmux.ui-scale-settings")
    private static let persistenceDebounceInterval: TimeInterval = 0.15
    private static let persistenceStateLock = NSLock()
    private static var pendingPersistenceWorkItem: DispatchWorkItem?
    private static var latestPersistenceGeneration: UInt64 = 0
    private static var completedPersistenceGeneration: UInt64 = 0

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
            persistAppUIScaleInBackground(
                next,
                settingsFileStore: settingsFileStore ?? KeyboardShortcutSettings.settingsFileStore
            )
        }
        notificationCenter.post(name: didChangeNotification, object: nil, userInfo: ["value": next])
        return next
    }

    @discardableResult
    static func zoomIn() -> Double {
        set(resolved() + keyboardStep)
    }

    @discardableResult
    static func zoomOut() -> Double {
        set(resolved() - keyboardStep)
    }

    @discardableResult
    static func reset() -> Double {
        set(defaultValue)
    }

    static func scaled(_ value: CGFloat, by uiScaleFactor: Double) -> CGFloat {
        value * CGFloat(clamped(uiScaleFactor))
    }

    static func roundedForPersistence(_ value: Double) -> Double {
        (clamped(value) * 100).rounded() / 100
    }

    static func shouldApplySettingsFileValue(
        _ value: Double,
        defaults: UserDefaults = .standard
    ) -> Bool {
        let persisted = roundedForPersistence(value)
        let current = roundedForPersistence(resolved(defaults: defaults))
        persistenceStateLock.lock()
        let hasPendingLocalPersistence = completedPersistenceGeneration < latestPersistenceGeneration
        persistenceStateLock.unlock()
        return !hasPendingLocalPersistence || persisted == current
    }

    private static func persistAppUIScaleInBackground(
        _ value: Double,
        settingsFileStore: CmuxSettingsFileStore
    ) {
        let generation = nextPersistenceGeneration()
        let workItem = DispatchWorkItem {
            guard isCurrentPersistenceGeneration(generation) else { return }
            do {
                try settingsFileStore.writeAppUIScale(value)
                completePersistenceGeneration(generation)
                DispatchQueue.main.async {
                    guard isCurrentPersistenceGeneration(generation) else { return }
                    settingsFileStore.reload()
                }
            } catch {
                completePersistenceGeneration(generation)
                logger.error(
                    "Failed to persist \(jsonPath, privacy: .public): \(String(describing: error), privacy: .public)"
                )
            }
        }
        persistenceStateLock.lock()
        pendingPersistenceWorkItem?.cancel()
        pendingPersistenceWorkItem = workItem
        persistenceStateLock.unlock()
        persistenceQueue.asyncAfter(deadline: .now() + persistenceDebounceInterval, execute: workItem)
    }

    private static func nextPersistenceGeneration() -> UInt64 {
        persistenceStateLock.lock()
        latestPersistenceGeneration &+= 1
        let generation = latestPersistenceGeneration
        persistenceStateLock.unlock()
        return generation
    }

    private static func isCurrentPersistenceGeneration(_ generation: UInt64) -> Bool {
        persistenceStateLock.lock()
        let isCurrent = generation == latestPersistenceGeneration
        persistenceStateLock.unlock()
        return isCurrent
    }

    private static func completePersistenceGeneration(_ generation: UInt64) {
        persistenceStateLock.lock()
        if generation == latestPersistenceGeneration {
            completedPersistenceGeneration = generation
        }
        persistenceStateLock.unlock()
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
