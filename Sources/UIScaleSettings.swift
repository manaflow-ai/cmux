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
    private static let persistenceCoordinator = UIScaleSettingsPersistenceCoordinator()
    private static let pendingPersistenceDomainName = "ai.manaflow.cmux.ui-scale-settings.pending"
    private static let pendingPersistenceIdentifierKey = "identifier"
    private static let pendingPersistenceValueKey = "value"

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
        guard let pending = pendingPersistence(defaults: defaults) else {
            return true
        }
        return roundedForPersistence(pending.value) != current || persisted == current
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
        // Volatile defaults make the synchronous settings-file parser aware of
        // an in-flight local write without adding a lock or blocking queue.
        defaults.setVolatileDomain(
            [
                pendingPersistenceIdentifierKey: identifier,
                pendingPersistenceValueKey: roundedForPersistence(value),
            ],
            forName: pendingPersistenceDomainName
        )
    }

    private static func pendingPersistence(defaults: UserDefaults) -> (identifier: String, value: Double)? {
        let domain = defaults.volatileDomain(forName: pendingPersistenceDomainName)
        guard let identifier = domain[pendingPersistenceIdentifierKey] as? String,
              let number = domain[pendingPersistenceValueKey] as? NSNumber else {
            return nil
        }
        return (identifier, number.doubleValue)
    }

    private static func clearPendingPersistence(defaults: UserDefaults) {
        defaults.removeVolatileDomain(forName: pendingPersistenceDomainName)
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
                try settingsFileStore.writeAppUIScale(value)
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
