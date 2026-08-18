import AppKit
import CmuxFilePreviewSyntax
import CmuxFoundation

/// Owns bounded, cancellable syntax-highlighting work for one file-preview text view.
@MainActor
final class FilePreviewSyntaxHighlightController {
    private enum TaskKey: Hashable, Sendable {
        case highlight
    }

    private struct Configuration: Equatable {
        let language: FilePreviewSyntaxLanguage?
        let appearance: FilePreviewSyntaxAppearance
        let enabled: Bool
    }

    private struct Request: Sendable {
        let revision: UInt64
        let sourceUTF16Length: Int
        let appearance: FilePreviewSyntaxAppearance
    }

    private weak var textView: NSTextView?
    private let highlighter = FilePreviewSyntaxHighlighter()
    private let paletteCatalog = FilePreviewSyntaxPaletteCatalog()
    private let policy: FilePreviewSyntaxHighlightPolicy
    private let tasks = MainActorTaskStore<TaskKey>()
    private var configuration = Configuration(
        language: nil,
        appearance: .dark,
        enabled: FilePreviewSyntaxHighlightSettings.defaultEnabled
    )
    private var revision: UInt64 = 0
    private var hasTemporaryColors = false

    private lazy var editDebounceTimer = MainActorCoalescingDeadlineTimer(owner: self) { owner in
        owner.refresh()
    }

    private static let editDebounceDuration: Duration = .milliseconds(180)

    init(
        textView: NSTextView,
        policy: FilePreviewSyntaxHighlightPolicy = FilePreviewSyntaxHighlightPolicy()
    ) {
        self.textView = textView
        self.policy = policy
    }

    /// Updates the filename, appearance, and user-preference inputs.
    ///
    /// - Returns: Whether the effective configuration changed.
    @discardableResult
    func configure(
        language: FilePreviewSyntaxLanguage?,
        appearance: FilePreviewSyntaxAppearance,
        enabled: Bool
    ) -> Bool {
        let next = Configuration(
            language: language,
            appearance: appearance,
            enabled: enabled
        )
        guard next != configuration else { return false }
        configuration = next
        return true
    }

    /// Invalidates in-flight colors immediately and coalesces the next edit-driven scan.
    func textDidChange() {
        guard isEligibleForCurrentText || hasTemporaryColors else { return }
        invalidateWork()
        clearTemporaryColors()
        guard isEligibleForCurrentText else { return }
        editDebounceTimer.schedule(after: Self.editDebounceDuration)
    }

    /// Starts a fresh scan or selects the plain-text degradation path.
    func refresh() {
        editDebounceTimer.cancel()
        invalidateWork()

        guard let textView,
              let language = configuration.language else {
            clearTemporaryColors()
            return
        }
        let sourceUTF16Length = textView.textStorage?.length ?? 0
        guard policy.allowsHighlighting(
            enabled: configuration.enabled,
            language: language,
            utf16Length: sourceUTF16Length
        ) else {
            clearTemporaryColors()
            return
        }
        let source = textView.string

        let request = Request(
            revision: revision,
            sourceUTF16Length: sourceUTF16Length,
            appearance: configuration.appearance
        )
        let highlighter = highlighter
        let maximumTokenCount = policy.maximumTokenCount
        tasks.replaceOnMainActor(.highlight, priority: .userInitiated) { [weak self] in
            let result = await highlighter.highlightOffMain(
                source,
                language: language,
                maximumTokenCount: maximumTokenCount
            )
            guard !Task.isCancelled else { return }
            self?.apply(result, for: request)
        }
    }

    /// Cancels every lifecycle-owned timer and scan.
    func cancel() {
        editDebounceTimer.cancel()
        invalidateWork()
    }

    private var isEligibleForCurrentText: Bool {
        guard let textView else { return false }
        return policy.allowsHighlighting(
            enabled: configuration.enabled,
            language: configuration.language,
            utf16Length: textView.textStorage?.length ?? 0
        )
    }

    private func invalidateWork() {
        revision &+= 1
        tasks.cancel(.highlight)
    }

    private func apply(
        _ result: FilePreviewSyntaxHighlightResult,
        for request: Request
    ) {
        guard request.revision == revision,
              let textView,
              textView.textStorage?.length == request.sourceUTF16Length else { return }
        guard policy.accepts(result) else {
            clearTemporaryColors()
            return
        }
        guard let layoutManager = textView.textContainer?.layoutManager else { return }

        clearTemporaryColors()
        let palette = paletteCatalog.palette(for: request.appearance)
        for token in result.tokens {
            let range = NSRange(
                location: token.utf16Range.lowerBound,
                length: token.utf16Range.count
            )
            guard range.length > 0,
                  range.location >= 0,
                  range.location + range.length <= request.sourceUTF16Length else { continue }
            let color = palette.color(for: token.kind)
            layoutManager.addTemporaryAttribute(
                .foregroundColor,
                value: NSColor(
                    srgbRed: CGFloat(color.red),
                    green: CGFloat(color.green),
                    blue: CGFloat(color.blue),
                    alpha: CGFloat(color.alpha)
                ),
                forCharacterRange: range
            )
        }
        hasTemporaryColors = !result.tokens.isEmpty
    }

    private func clearTemporaryColors() {
        guard hasTemporaryColors,
              let textView,
              let layoutManager = textView.textContainer?.layoutManager else { return }
        layoutManager.removeTemporaryAttribute(
            .foregroundColor,
            forCharacterRange: NSRange(
                location: 0,
                length: textView.textStorage?.length ?? 0
            )
        )
        hasTemporaryColors = false
    }
}

extension FilePreviewSyntaxAppearanceResolver {
    /// Resolves the syntax palette from an AppKit editor foreground color.
    func appearance(forForegroundColor foregroundColor: NSColor) -> FilePreviewSyntaxAppearance {
        guard let color = foregroundColor.usingColorSpace(.sRGB) else { return .dark }
        return appearance(
            forForegroundRed: Double(color.redComponent),
            green: Double(color.greenComponent),
            blue: Double(color.blueComponent)
        )
    }
}
