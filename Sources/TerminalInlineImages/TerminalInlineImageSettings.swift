import Foundation

enum TerminalInlineImageSettings {
    static let inlineImageThumbnailsKey = "terminal.inlineImageThumbnails"
    static let defaultInlineImageThumbnails = true

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: inlineImageThumbnailsKey) == nil {
            return defaultInlineImageThumbnails
        }
        return defaults.bool(forKey: inlineImageThumbnailsKey)
    }
}

@MainActor
final class TerminalInlineImageSettingsObserver {
    private let defaults: UserDefaults
    private let notificationCenter: NotificationCenter
    private let handler: @MainActor (Bool) -> Void
    private var observer: NSObjectProtocol?
    private var lastDeliveredValue: Bool

    init(
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default,
        handler: @escaping @MainActor (Bool) -> Void
    ) {
        self.defaults = defaults
        self.notificationCenter = notificationCenter
        self.handler = handler
        lastDeliveredValue = TerminalInlineImageSettings.isEnabled(defaults: defaults)
    }

    func start() {
        guard observer == nil else { return }
        lastDeliveredValue = TerminalInlineImageSettings.isEnabled(defaults: defaults)
        observer = notificationCenter.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.deliverCurrentValueIfChanged()
            }
        }
    }

    func stop() {
        if let observer {
            notificationCenter.removeObserver(observer)
            self.observer = nil
        }
    }

    private func deliverCurrentValueIfChanged() {
        let enabled = TerminalInlineImageSettings.isEnabled(defaults: defaults)
        guard enabled != lastDeliveredValue else { return }
        lastDeliveredValue = enabled
        handler(enabled)
    }

    deinit {
        if let observer {
            notificationCenter.removeObserver(observer)
        }
    }
}
