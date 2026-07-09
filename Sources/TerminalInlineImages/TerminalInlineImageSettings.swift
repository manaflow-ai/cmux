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

final class TerminalInlineImageSettingsObserver: NSObject {
    private let defaults: UserDefaults
    private let handler: @MainActor @Sendable (Bool) -> Void
    private var isObserving = false

    init(
        defaults: UserDefaults = .standard,
        handler: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        self.defaults = defaults
        self.handler = handler
        super.init()
    }

    func start() {
        guard !isObserving else { return }
        isObserving = true
        defaults.addObserver(
            self,
            forKeyPath: TerminalInlineImageSettings.inlineImageThumbnailsKey,
            options: [.initial, .new],
            context: nil
        )
    }

    func stop() {
        guard isObserving else { return }
        defaults.removeObserver(self, forKeyPath: TerminalInlineImageSettings.inlineImageThumbnailsKey)
        isObserving = false
    }

    override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        guard keyPath == TerminalInlineImageSettings.inlineImageThumbnailsKey else { return }
        let enabled = TerminalInlineImageSettings.isEnabled(defaults: defaults)
        Task { @MainActor in
            handler(enabled)
        }
    }

    deinit {
        stop()
    }
}
