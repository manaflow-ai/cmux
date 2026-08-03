import AppKit
import CmuxFoundation

/// Displays the Stack profile image with an initial-based native fallback.
@MainActor
final class StackAccountAvatarView: NSView {
    private let imageView = NSImageView(frame: .zero)
    private let fallbackLabel = NSTextField(labelWithString: "")
    private let fallbackSymbol = NSImageView(frame: .zero)
    private var loadTask: Task<Void, Never>?
    private var avatarURL: URL?
    private var displayName: String
    private var email: String
    private let side: CGFloat
    private let loadingSystemName: String?

    init(
        avatarURL: URL?,
        displayName: String,
        email: String,
        size: CGFloat,
        loadingSystemName: String? = nil
    ) {
        self.avatarURL = avatarURL
        self.displayName = displayName
        self.email = email
        side = size
        self.loadingSystemName = loadingSystemName
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        wantsLayer = true
        layer?.cornerRadius = size / 2
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
        imageView.imageScaling = .scaleProportionallyUpOrDown
        fallbackLabel.alignment = .center
        fallbackLabel.font = GlobalFontMagnification.systemFont(ofSize: max(8, size * 0.4), weight: .semibold)
        fallbackSymbol.imageScaling = .scaleProportionallyDown
        addSubview(fallbackSymbol)
        addSubview(fallbackLabel)
        addSubview(imageView)
        setAccessibilityElement(false)
        updateFallback()
        loadAvatar()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit { loadTask?.cancel() }

    override var intrinsicContentSize: NSSize { NSSize(width: side, height: side) }

    override func layout() {
        super.layout()
        imageView.frame = bounds
        fallbackLabel.frame = bounds
        fallbackSymbol.frame = bounds.insetBy(dx: side * 0.24, dy: side * 0.24)
        layer?.cornerRadius = min(bounds.width, bounds.height) / 2
    }

    func update(avatarURL: URL?, displayName: String, email: String) {
        let shouldReload = self.avatarURL != avatarURL
        self.avatarURL = avatarURL
        self.displayName = displayName
        self.email = email
        updateFallback()
        if shouldReload { loadAvatar() }
    }

    private func updateFallback() {
        let foreground = loadingSystemName == nil ? NSColor.controlAccentColor : .secondaryLabelColor
        layer?.backgroundColor = foreground.withAlphaComponent(0.18).cgColor
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = trimmedName.isEmpty ? email : trimmedName
        if let initial = source.first.map({ String($0).uppercased() }) {
            fallbackLabel.stringValue = initial
            fallbackLabel.textColor = foreground
            fallbackLabel.isHidden = false
            fallbackSymbol.isHidden = true
        } else {
            let symbolName = loadingSystemName ?? "person.fill"
            fallbackSymbol.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: max(8, side * 0.45), weight: .medium))
            fallbackSymbol.contentTintColor = foreground
            fallbackSymbol.isHidden = false
            fallbackLabel.isHidden = true
        }
    }

    private func loadAvatar() {
        loadTask?.cancel()
        imageView.image = nil
        imageView.isHidden = true
        guard let avatarURL else { return }
        loadTask = Task { @MainActor [weak self] in
            do {
                let (data, response) = try await URLSession.shared.data(from: avatarURL)
                guard !Task.isCancelled,
                      let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode),
                      let image = NSImage(data: data),
                      let self,
                      self.avatarURL == avatarURL else { return }
                imageView.image = image
                imageView.isHidden = false
            } catch {
                // The initial/symbol fallback is already visible.
            }
        }
    }
}
