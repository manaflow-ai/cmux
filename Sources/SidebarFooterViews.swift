import AppKit
import CmuxSocketControl
import Bonsplit
import Combine
@_spi(CmuxHostTransport) import CmuxExtensionKit
import CmuxSidebarProviderKit
import CmuxExtensionSidebarExamples
import CmuxSettings
import CmuxSettingsUI
import CmuxSidebarRemoteRender
import CmuxSwiftRender
import CmuxSwiftRenderUI
import CmuxUpdater
import CmuxUpdaterUI
import ImageIO
import Observation
import SwiftUI
import ObjectiveC
import UniformTypeIdentifiers
import WebKit

struct SidebarFooter: View {
    var updateViewModel: UpdateStateModel
    @ObservedObject var fileExplorerState: FileExplorerState
    let onSendFeedback: () -> Void

    var body: some View {
#if DEBUG
        SidebarDevFooter(updateViewModel: updateViewModel, fileExplorerState: fileExplorerState, onSendFeedback: onSendFeedback)
#else
        SidebarFooterButtons(updateViewModel: updateViewModel, fileExplorerState: fileExplorerState, onSendFeedback: onSendFeedback)
            .padding(.leading, 6)
            .padding(.trailing, 10)
            .padding(.bottom, 6)
#endif
    }
}

private struct SidebarFooterButtons: View {
    var updateViewModel: UpdateStateModel
    @ObservedObject var fileExplorerState: FileExplorerState
    let onSendFeedback: () -> Void
    @State private var extensionBrowserAnchorView: NSView?
    @LiveSetting(\.betaFeatures.extensions) private var extensionsExperimentalEnabled

    var body: some View {
        HStack(spacing: 4) {
            SidebarHelpMenuButton(onSendFeedback: onSendFeedback)
            // The puzzle button opens the extensions browser; it only shows
            // while the experimental Extensions feature is enabled.
            if extensionsExperimentalEnabled {
                Button {
                    _ = AppDelegate.shared?.openSidebarExtensionBrowser(
                        from: extensionBrowserAnchorView,
                        title: String(localized: "sidebar.extensions.browser.title", defaultValue: "Sidebar Extensions")
                    )
                } label: {
                    Image(systemName: "puzzlepiece.extension")
                        .symbolRenderingMode(.monochrome)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                        .frame(width: 22, height: 22, alignment: .center)
                }
                .buttonStyle(SidebarFooterIconButtonStyle())
                .frame(width: 22, height: 22, alignment: .center)
                .safeHelp(String(localized: "sidebar.extensions.browser.title", defaultValue: "Sidebar Extensions"))
                .accessibilityLabel(String(localized: "sidebar.extensions.browser.title", defaultValue: "Sidebar Extensions"))
                .accessibilityIdentifier("SidebarExtensionMenuButton")
                .background(TitlebarControlAnchorView { extensionBrowserAnchorView = $0 })
            }
            if let updateActionsHost = AppDelegate.shared {
                UpdatePill(model: updateViewModel, accent: cmuxAccentColor(), actions: updateActionsHost)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct FeedbackComposerMessageEditor: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let accessibilityLabel: String
    let accessibilityIdentifier: String

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> FeedbackComposerMessageEditorView {
        let view = FeedbackComposerMessageEditorView()
        view.placeholder = placeholder
        view.textView.string = text
        view.textView.delegate = context.coordinator
        view.textView.setAccessibilityLabel(accessibilityLabel)
        view.textView.setAccessibilityIdentifier(accessibilityIdentifier)
        view.setAccessibilityIdentifier(accessibilityIdentifier)
        return view
    }

    func updateNSView(_ nsView: FeedbackComposerMessageEditorView, context: Context) {
        if nsView.textView.string != text {
            nsView.textView.string = text
            nsView.refreshTextLayout()
        }
        nsView.placeholder = placeholder
        nsView.textView.setAccessibilityLabel(accessibilityLabel)
        nsView.textView.setAccessibilityIdentifier(accessibilityIdentifier)
        nsView.setAccessibilityIdentifier(accessibilityIdentifier)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: FeedbackComposerMessageEditor

        init(parent: FeedbackComposerMessageEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}

private final class FeedbackComposerPassthroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class FeedbackComposerMessageScrollView: NSScrollView {
    weak var focusTextView: NSTextView?

    override func mouseDown(with event: NSEvent) {
        if let focusTextView {
            _ = window?.makeFirstResponder(focusTextView)
        }
        super.mouseDown(with: event)
    }
}

final class FeedbackComposerMessageEditorView: NSView {
    private static let font = NSFont.systemFont(ofSize: 12)
    private static let textInset = NSSize(width: 10, height: 10)
    private static let minimumDocumentHeight: CGFloat = {
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        return lineHeight + textInset.height * 2
    }()

    let scrollView = FeedbackComposerMessageScrollView()
    let textView = NSTextView()
    private let placeholderField = FeedbackComposerPassthroughLabel(labelWithString: "")

    var placeholder: String = "" {
        didSet {
            placeholderField.stringValue = placeholder
            updatePlaceholderVisibility()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.focusTextView = textView

        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.font = Self.font
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.textContainerInset = Self.textInset
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.minSize = NSSize(width: 0, height: Self.minimumDocumentHeight)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )

        scrollView.documentView = textView
        addSubview(scrollView)

        placeholderField.translatesAutoresizingMaskIntoConstraints = false
        placeholderField.font = Self.font
        placeholderField.textColor = .secondaryLabelColor
        placeholderField.lineBreakMode = .byWordWrapping
        placeholderField.maximumNumberOfLines = 0
        scrollView.contentView.addSubview(placeholderField)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(textDidChange(_:)),
            name: NSText.didChangeNotification,
            object: textView
        )

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),

            placeholderField.topAnchor.constraint(
                equalTo: scrollView.contentView.topAnchor,
                constant: Self.textInset.height
            ),
            placeholderField.leadingAnchor.constraint(
                equalTo: scrollView.contentView.leadingAnchor,
                constant: Self.textInset.width
            ),
            placeholderField.trailingAnchor.constraint(
                lessThanOrEqualTo: scrollView.contentView.trailingAnchor,
                constant: -Self.textInset.width
            ),
        ])

        updatePlaceholderVisibility()
    }

    override func layout() {
        super.layout()
        syncTextViewFrameToContentSize()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc
    private func textDidChange(_ notification: Notification) {
        refreshTextLayout(scrollSelection: true)
    }

    private func updatePlaceholderVisibility() {
        placeholderField.isHidden = textView.string.isEmpty == false
    }

    func refreshTextLayout(scrollSelection: Bool = false) {
        updatePlaceholderVisibility()
        needsLayout = true
        layoutSubtreeIfNeeded()
        syncTextViewFrameToContentSize()
        if scrollSelection {
            textView.scrollRangeToVisible(textView.selectedRange())
        }
    }

    private func naturalDocumentHeight(for width: CGFloat) -> CGFloat {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else {
            return Self.minimumDocumentHeight
        }

        let textWidth = max(width - Self.textInset.width * 2, 1)
        textContainer.containerSize = NSSize(
            width: textWidth,
            height: CGFloat.greatestFiniteMagnitude
        )
        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        let extraLineHeight: CGFloat
        if layoutManager.extraLineFragmentTextContainer === textContainer {
            extraLineHeight = ceil(layoutManager.extraLineFragmentRect.height)
        } else {
            extraLineHeight = 0
        }
        let lineHeight = ceil(Self.font.ascender - Self.font.descender + Self.font.leading)
        let contentHeight = max(lineHeight, ceil(usedRect.height) + extraLineHeight)
        return max(
            Self.minimumDocumentHeight,
            ceil(contentHeight + Self.textInset.height * 2)
        )
    }

    private func syncTextViewFrameToContentSize() {
        let contentSize = scrollView.contentSize
        guard contentSize.width > 0, contentSize.height > 0 else { return }

        textView.minSize = NSSize(width: 0, height: contentSize.height)
        let naturalHeight = naturalDocumentHeight(for: contentSize.width)
        let targetSize = NSSize(
            width: contentSize.width,
            height: max(naturalHeight, contentSize.height)
        )
        if textView.frame.size != targetSize {
            textView.frame = NSRect(origin: .zero, size: targetSize)
        }
    }
}

private enum SidebarHelpMenuAction {
    case importBrowserData
    case keyboardShortcuts
    case docs
    case changelog
    case github
    case githubIssues
    case discord
    case checkForUpdates
    case sendFeedback
    case welcome
}

struct SidebarFeedbackComposerSheet: View {
    private static let formMaxHeight: CGFloat = 560

    @AppStorage(FeedbackComposerSettings.storedEmailKey) private var email = ""
    @Environment(\.dismiss) private var dismiss

    @State private var message = ""
    @State private var attachments: [FeedbackComposerAttachment] = []
    @State private var isSubmitting = false
    @State private var submissionErrorMessage: String?
    @State private var didSend = false

    private var trimmedMessage: String {
        message.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmit: Bool {
        isValidEmail(email) &&
            !trimmedMessage.isEmpty &&
            message.count <= FeedbackComposerSettings.maxMessageLength &&
            !isSubmitting &&
            !didSend
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(String(localized: "sidebar.help.feedback.title", defaultValue: "Send Feedback"))
                .font(.title3.weight(.semibold))

            if didSend {
                successView
            } else {
                ScrollView {
                    formView
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.trailing, 4)
                }
                .frame(maxHeight: Self.formMaxHeight)
            }
        }
        .padding(20)
        .frame(width: 520)
        .accessibilityIdentifier("SidebarFeedbackDialog")
    }

    private var successView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "sidebar.help.feedback.successTitle", defaultValue: "Thanks for the feedback."))
                .font(.headline)
            Text(
                String(
                    localized: "sidebar.help.feedback.successBody",
                    defaultValue: "You can also reach us at founders@manaflow.com."
                )
            )
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)

            HStack {
                Spacer()
                Button(String(localized: "sidebar.help.feedback.done", defaultValue: "Done")) {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var formView: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(
                String(
                    localized: "sidebar.help.feedback.note",
                    defaultValue: "A human will read this! You can also reach us at founders@manaflow.com."
                )
            )
            .font(.system(size: 12))
            .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "sidebar.help.feedback.email", defaultValue: "Your Email"))
                    .font(.system(size: 12, weight: .medium))
                TextField(
                    String(localized: "sidebar.help.feedback.emailPlaceholder", defaultValue: "you@example.com"),
                    text: $email
                )
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(String(localized: "sidebar.help.feedback.email", defaultValue: "Your Email"))
                .accessibilityIdentifier("SidebarFeedbackEmailField")
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(String(localized: "sidebar.help.feedback.message", defaultValue: "Message"))
                        .font(.system(size: 12, weight: .medium))
                    Spacer(minLength: 0)
                    Text("\(message.count)/\(FeedbackComposerSettings.maxMessageLength)")
                        .font(.system(size: 11))
                        .foregroundStyle(
                            message.count > FeedbackComposerSettings.maxMessageLength
                                ? Color.red
                                : Color.secondary
                        )
                }

                FeedbackComposerMessageEditor(
                    text: $message,
                    placeholder: String(
                        localized: "sidebar.help.feedback.messagePlaceholder",
                        defaultValue: "Share feedback, feature requests, or issues."
                    ),
                    accessibilityLabel: String(localized: "sidebar.help.feedback.message", defaultValue: "Message"),
                    accessibilityIdentifier: "SidebarFeedbackMessageEditor"
                )
                .frame(minHeight: 180)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Button {
                        chooseAttachments()
                    } label: {
                        Label(
                            String(localized: "sidebar.help.feedback.attachImages", defaultValue: "Attach Images"),
                            systemImage: "paperclip"
                        )
                    }
                    .accessibilityIdentifier("SidebarFeedbackAttachButton")

                    Text(
                        String(
                            localized: "sidebar.help.feedback.attachmentsHint",
                            defaultValue: "Up to 10 images."
                        )
                    )
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }

                if attachments.isEmpty == false {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(attachments) { attachment in
                            HStack(spacing: 8) {
                                Image(systemName: "photo")
                                    .foregroundStyle(.secondary)
                                Text(attachment.fileName)
                                    .font(.system(size: 12))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 0)
                                Text(attachment.displaySize)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                Button(
                                    String(localized: "sidebar.help.feedback.removeAttachment", defaultValue: "Remove")
                                ) {
                                    removeAttachment(attachment)
                                }
                                .buttonStyle(.link)
                            }
                        }
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.primary.opacity(0.04))
                    )
                }
            }

            if let submissionErrorMessage, submissionErrorMessage.isEmpty == false {
                Text(submissionErrorMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button(String(localized: "sidebar.help.feedback.cancel", defaultValue: "Cancel")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button {
                    Task { await submitFeedback() }
                } label: {
                    if isSubmitting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(String(localized: "sidebar.help.feedback.send", defaultValue: "Send"))
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
                .accessibilityIdentifier("SidebarFeedbackSendButton")
            }
        }
    }

    private func chooseAttachments() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        panel.title = String(
            localized: "sidebar.help.feedback.attachImages.title",
            defaultValue: "Attach Images"
        )
        panel.prompt = String(
            localized: "sidebar.help.feedback.attachImages.prompt",
            defaultValue: "Attach"
        )

        guard panel.runModal() == .OK else { return }

        var updatedAttachments = attachments
        var knownPaths = Set(updatedAttachments.map(\.standardizedPath))
        var firstIssue: String?

        for url in panel.urls {
            let normalizedPath = url.standardizedFileURL.path
            if knownPaths.contains(normalizedPath) {
                continue
            }
            if updatedAttachments.count >= FeedbackComposerSettings.maxAttachmentCount {
                firstIssue = String(
                    localized: "sidebar.help.feedback.tooManyImages",
                    defaultValue: "You can attach up to 10 images."
                )
                break
            }

            guard let attachment = try? FeedbackComposerAttachment(url: url) else {
                firstIssue = String(
                    localized: "sidebar.help.feedback.invalidImageSelection",
                    defaultValue: "One of the selected files could not be attached."
                )
                continue
            }
            updatedAttachments.append(attachment)
            knownPaths.insert(normalizedPath)
        }

        attachments = updatedAttachments
        submissionErrorMessage = firstIssue
    }

    private func removeAttachment(_ attachment: FeedbackComposerAttachment) {
        attachments.removeAll { $0.id == attachment.id }
        submissionErrorMessage = nil
    }

    private func submitFeedback() async {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedMessage = trimmedMessage

        guard isValidEmail(trimmedEmail) else {
            submissionErrorMessage = String(
                localized: "sidebar.help.feedback.invalidEmail",
                defaultValue: "Enter a valid email address."
            )
            return
        }

        guard normalizedMessage.isEmpty == false else {
            submissionErrorMessage = String(
                localized: "sidebar.help.feedback.emptyMessage",
                defaultValue: "Enter a message before sending."
            )
            return
        }

        guard message.count <= FeedbackComposerSettings.maxMessageLength else {
            submissionErrorMessage = String(
                localized: "sidebar.help.feedback.messageTooLong",
                defaultValue: "Your message is too long."
            )
            return
        }

        await MainActor.run {
            email = trimmedEmail
            submissionErrorMessage = nil
            isSubmitting = true
        }

        do {
            try await FeedbackComposerClient.submit(
                email: trimmedEmail,
                message: normalizedMessage,
                attachments: attachments
            )
            await MainActor.run {
                isSubmitting = false
                didSend = true
                attachments = []
            }
        } catch {
            await MainActor.run {
                isSubmitting = false
                submissionErrorMessage = userFacingErrorMessage(for: error)
            }
        }
    }

    private func isValidEmail(_ rawValue: String) -> Bool {
        let email = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard email.isEmpty == false else { return false }
        let pattern = #"^[A-Z0-9a-z._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$"#
        return NSPredicate(format: "SELF MATCHES %@", pattern).evaluate(with: email)
    }

    private func userFacingErrorMessage(for error: Error) -> String {
        guard let submissionError = error as? FeedbackComposerSubmissionError else {
            return String(
                localized: "sidebar.help.feedback.genericError",
                defaultValue: "Couldn't send feedback. Please try again."
            )
        }

        switch submissionError {
        case .invalidEndpoint:
            return String(
                localized: "sidebar.help.feedback.endpointError",
                defaultValue: "Feedback is unavailable right now. Email founders@manaflow.com instead."
            )
        case .invalidResponse:
            return String(
                localized: "sidebar.help.feedback.genericError",
                defaultValue: "Couldn't send feedback. Please try again."
            )
        case .attachmentReadFailed:
            return String(
                localized: "sidebar.help.feedback.invalidImageSelection",
                defaultValue: "One of the selected files could not be attached."
            )
        case .attachmentPreparationFailed:
            return String(
                localized: "sidebar.help.feedback.totalImagesTooLarge",
                defaultValue: "These images are too large to send together. Remove a few and try again."
            )
        case .transport(let transportError):
            if transportError.code == .notConnectedToInternet || transportError.code == .networkConnectionLost {
                return String(
                    localized: "sidebar.help.feedback.connectionError",
                    defaultValue: "Couldn't send feedback. Check your connection and try again."
                )
            }
            return String(
                localized: "sidebar.help.feedback.genericError",
                defaultValue: "Couldn't send feedback. Please try again."
            )
        case .rejected(let statusCode):
            switch statusCode {
            case 400, 413, 415:
                return String(
                    localized: "sidebar.help.feedback.validationError",
                    defaultValue: "Check your message and attachments, then try again."
                )
            case 429:
                return String(
                    localized: "sidebar.help.feedback.rateLimited",
                    defaultValue: "Too many feedback attempts. Please try again later."
                )
            case 500...599:
                return String(
                    localized: "sidebar.help.feedback.endpointError",
                    defaultValue: "Feedback is unavailable right now. Email founders@manaflow.com instead."
                )
            default:
                return String(
                    localized: "sidebar.help.feedback.genericError",
                    defaultValue: "Couldn't send feedback. Please try again."
                )
            }
        }
    }
}

enum FeedbackComposerBridgeError: LocalizedError {
    case invalidEmail
    case emptyMessage
    case messageTooLong
    case tooManyImages
    case invalidImagePath(String)
    case submissionFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidEmail:
            return "Enter a valid email address."
        case .emptyMessage:
            return "Enter a message before sending."
        case .messageTooLong:
            return "Your message is too long."
        case .tooManyImages:
            return "You can attach up to 10 images."
        case .invalidImagePath(let path):
            return "Could not attach image: \(path)"
        case .submissionFailed(let message):
            return message
        }
    }
}

enum FeedbackComposerBridge {
    static func openComposer(in window: NSWindow? = NSApp.keyWindow ?? NSApp.mainWindow) {
        NotificationCenter.default.post(name: .feedbackComposerRequested, object: window)
    }

    static func submit(
        email: String,
        message: String,
        imagePaths: [String]
    ) async throws -> Int {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)

        guard isValidEmail(trimmedEmail) else {
            throw FeedbackComposerBridgeError.invalidEmail
        }
        guard normalizedMessage.isEmpty == false else {
            throw FeedbackComposerBridgeError.emptyMessage
        }
        guard message.count <= FeedbackComposerSettings.maxMessageLength else {
            throw FeedbackComposerBridgeError.messageTooLong
        }
        guard imagePaths.count <= FeedbackComposerSettings.maxAttachmentCount else {
            throw FeedbackComposerBridgeError.tooManyImages
        }

        let attachments = try imagePaths.map { rawPath in
            let resolvedURL = URL(fileURLWithPath: rawPath).standardizedFileURL
            do {
                return try FeedbackComposerAttachment(url: resolvedURL)
            } catch {
                throw FeedbackComposerBridgeError.invalidImagePath(resolvedURL.path)
            }
        }

        do {
            try await FeedbackComposerClient.submit(
                email: trimmedEmail,
                message: normalizedMessage,
                attachments: attachments
            )
        } catch {
            throw FeedbackComposerBridgeError.submissionFailed(userFacingMessage(for: error))
        }

        UserDefaults.standard.set(trimmedEmail, forKey: FeedbackComposerSettings.storedEmailKey)
        return attachments.count
    }

    private static func isValidEmail(_ rawValue: String) -> Bool {
        let email = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard email.isEmpty == false else { return false }
        let pattern = #"^[A-Z0-9a-z._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$"#
        return NSPredicate(format: "SELF MATCHES %@", pattern).evaluate(with: email)
    }

    private static func userFacingMessage(for error: Error) -> String {
        guard let submissionError = error as? FeedbackComposerSubmissionError else {
            return "Couldn't send feedback. Please try again."
        }

        switch submissionError {
        case .invalidEndpoint:
            return "Feedback is unavailable right now. Email founders@manaflow.com instead."
        case .invalidResponse:
            return "Couldn't send feedback. Please try again."
        case .attachmentReadFailed:
            return "One of the selected files could not be attached."
        case .attachmentPreparationFailed:
            return "These images are too large to send together. Remove a few and try again."
        case .transport(let transportError):
            if transportError.code == .notConnectedToInternet || transportError.code == .networkConnectionLost {
                return "Couldn't send feedback. Check your connection and try again."
            }
            return "Couldn't send feedback. Please try again."
        case .rejected(let statusCode):
            switch statusCode {
            case 400, 413, 415:
                return "Check your message and attachments, then try again."
            case 429:
                return "Too many feedback attempts. Please try again later."
            case 500...599:
                return "Feedback is unavailable right now. Email founders@manaflow.com instead."
            default:
                return "Couldn't send feedback. Please try again."
            }
        }
    }
}

private struct SidebarHelpMenuButton: View {
    private let docsURL = URL(string: "https://cmux.com/docs")
    private let changelogURL = URL(string: "https://cmux.com/docs/changelog")
    private let githubURL = URL(string: "https://github.com/manaflow-ai/cmux")
    private let githubIssuesURL = URL(string: "https://github.com/manaflow-ai/cmux/issues")
    private let discordURL = URL(string: "https://discord.gg/xsgFEVrWCZ")
    private let helpTitle = String(localized: "sidebar.help.button", defaultValue: "Help")
    private let buttonSize: CGFloat = 22
    private let iconSize: CGFloat = 11
    @ObservedObject private var keyboardShortcutSettingsObserver = KeyboardShortcutSettingsObserver.shared

    let onSendFeedback: () -> Void

    @State private var isPopoverPresented = false

    private var sendFeedbackShortcutHint: String {
        let _ = keyboardShortcutSettingsObserver.revision
        return KeyboardShortcutSettings.shortcut(for: .sendFeedback).displayString
    }

    var body: some View {
        Button {
            isPopoverPresented.toggle()
        } label: {
            Image(systemName: "questionmark.circle")
                .symbolRenderingMode(.monochrome)
                .font(.system(size: iconSize, weight: .medium))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .frame(width: buttonSize, height: buttonSize, alignment: .center)
        }
        .buttonStyle(SidebarFooterIconButtonStyle())
        .frame(width: buttonSize, height: buttonSize, alignment: .center)
        .background(ArrowlessPopoverAnchor(
            isPresented: $isPopoverPresented,
            preferredEdge: .maxY,
            detachedGap: 4
        ) {
            helpPopover
        })
        .accessibilityElement(children: .ignore)
        .safeHelp(helpTitle)
        .accessibilityLabel(helpTitle)
        .accessibilityIdentifier("SidebarHelpMenuButton")
    }

    private var helpPopover: some View {
        VStack(alignment: .leading, spacing: 2) {
            helpOptionButton(
                title: String(localized: "sidebar.help.welcome", defaultValue: "Welcome to cmux!"),
                action: .welcome,
                accessibilityIdentifier: "SidebarHelpMenuOptionWelcome",
                isExternalLink: false
            )
            helpOptionButton(
                title: String(localized: "sidebar.help.sendFeedback", defaultValue: "Send Feedback"),
                action: .sendFeedback,
                accessibilityIdentifier: "SidebarHelpMenuOptionSendFeedback",
                isExternalLink: false,
                shortcutHint: sendFeedbackShortcutHint,
                trailingSystemImage: "bubble.left.and.text.bubble.right"
            )
            helpOptionButton(
                title: String(localized: "settings.section.keyboardShortcuts", defaultValue: "Keyboard Shortcuts"),
                action: .keyboardShortcuts,
                accessibilityIdentifier: "SidebarHelpMenuOptionKeyboardShortcuts",
                isExternalLink: false
            )
            helpOptionButton(
                title: String(localized: "menu.view.importFromBrowser", defaultValue: "Import Browser Data…"),
                action: .importBrowserData,
                accessibilityIdentifier: "SidebarHelpMenuOptionImportBrowserData",
                isExternalLink: false
            )
            if docsURL != nil {
                helpOptionButton(
                    title: String(localized: "about.docs", defaultValue: "Docs"),
                    action: .docs,
                    accessibilityIdentifier: "SidebarHelpMenuOptionDocs",
                    isExternalLink: true
                )
            }
            if changelogURL != nil {
                helpOptionButton(
                    title: String(localized: "sidebar.help.changelog", defaultValue: "Changelog"),
                    action: .changelog,
                    accessibilityIdentifier: "SidebarHelpMenuOptionChangelog",
                    isExternalLink: true
                )
            }
            if githubURL != nil {
                helpOptionButton(
                    title: String(localized: "about.github", defaultValue: "GitHub"),
                    action: .github,
                    accessibilityIdentifier: "SidebarHelpMenuOptionGitHub",
                    isExternalLink: true
                )
            }
            if githubIssuesURL != nil {
                helpOptionButton(
                    title: String(localized: "sidebar.help.githubIssues", defaultValue: "GitHub Issues"),
                    action: .githubIssues,
                    accessibilityIdentifier: "SidebarHelpMenuOptionGitHubIssues",
                    isExternalLink: true
                )
            }
            if discordURL != nil {
                helpOptionButton(
                    title: String(localized: "sidebar.help.discord", defaultValue: "Discord"),
                    action: .discord,
                    accessibilityIdentifier: "SidebarHelpMenuOptionDiscord",
                    isExternalLink: true
                )
            }
            helpOptionButton(
                title: String(localized: "command.checkForUpdates.title", defaultValue: "Check for Updates"),
                action: .checkForUpdates,
                accessibilityIdentifier: "SidebarHelpMenuOptionCheckForUpdates",
                isExternalLink: false
            )
        }
        .padding(8)
        .frame(minWidth: 200)
    }

    private func helpOptionButton(
        title: String,
        action: SidebarHelpMenuAction,
        accessibilityIdentifier: String,
        isExternalLink: Bool,
        shortcutHint: String? = nil,
        trailingSystemImage: String? = nil
    ) -> some View {
        Button {
            isPopoverPresented = false
            perform(action)
        } label: {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 12))
                Spacer(minLength: 0)
                if let shortcutHint {
                    helpOptionShortcutHint(text: shortcutHint)
                }
                if let trailingSystemImage {
                    helpOptionTrailingIcon(systemName: trailingSystemImage)
                }
                if isExternalLink {
                    helpOptionTrailingIcon(systemName: "arrow.up.right", size: 8)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private func helpOptionShortcutHint(text: String) -> some View {
        Text(text)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .font(.system(size: 10, weight: .regular, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
    }

    private func helpOptionTrailingIcon(systemName: String, size: CGFloat = 13) -> some View {
        Image(systemName: systemName)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
    }

    private func perform(_ action: SidebarHelpMenuAction) {
        switch action {
        case .importBrowserData:
            isPopoverPresented = false
            DispatchQueue.main.async {
                BrowserDataImportCoordinator.shared.presentImportDialog()
            }
        case .keyboardShortcuts:
            isPopoverPresented = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                Task { @MainActor in
                    if let appDelegate = AppDelegate.shared {
                        appDelegate.openPreferencesWindow(
                            debugSource: "sidebarHelpMenu.keyboardShortcuts",
                            navigationTarget: .keyboardShortcuts
                        )
                    } else {
                        AppDelegate.presentPreferencesWindow(navigationTarget: .keyboardShortcuts)
                    }
                }
            }
        case .docs:
            guard let docsURL else { return }
            NSWorkspace.shared.open(docsURL)
        case .changelog:
            guard let changelogURL else { return }
            NSWorkspace.shared.open(changelogURL)
        case .github:
            guard let githubURL else { return }
            NSWorkspace.shared.open(githubURL)
        case .githubIssues:
            guard let githubIssuesURL else { return }
            NSWorkspace.shared.open(githubIssuesURL)
        case .discord:
            guard let discordURL else { return }
            NSWorkspace.shared.open(discordURL)
        case .checkForUpdates:
            Task { @MainActor in
                AppDelegate.shared?.checkForUpdates(nil)
            }
        case .sendFeedback:
            isPopoverPresented = false
            onSendFeedback()
        case .welcome:
            isPopoverPresented = false
            Task { @MainActor in
                if let appDelegate = AppDelegate.shared {
                    appDelegate.openWelcomeWorkspace()
                }
            }
        }
    }

}

private struct ArrowlessPopoverAnchor<PopoverContent: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    let preferredEdge: NSRectEdge
    let detachedGap: CGFloat
    @ViewBuilder let content: () -> PopoverContent

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.anchorView = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.anchorView = nsView
        context.coordinator.updateRootView(AnyView(content()))

        if isPresented {
            context.coordinator.present(
                preferredEdge: preferredEdge,
                detachedGap: detachedGap
            )
        } else {
            context.coordinator.dismiss()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(isPresented: $isPresented)
    }

    final class Coordinator: NSObject, NSPopoverDelegate {
        @Binding var isPresented: Bool

        weak var anchorView: NSView?
        private let hostingController = NSHostingController(rootView: AnyView(EmptyView()))
        private var popover: NSPopover?

        init(isPresented: Binding<Bool>) {
            _isPresented = isPresented
        }

        func updateRootView(_ rootView: AnyView) {
            hostingController.rootView = AnyView(rootView.fixedSize())
            hostingController.view.invalidateIntrinsicContentSize()
            hostingController.view.layoutSubtreeIfNeeded()
        }

        func present(preferredEdge: NSRectEdge, detachedGap: CGFloat) {
            guard let anchorView else {
                isPresented = false
                dismiss()
                return
            }

            let popover = popover ?? makePopover()
            if popover.isShown {
                return
            }

            hostingController.view.invalidateIntrinsicContentSize()
            hostingController.view.layoutSubtreeIfNeeded()
            let fittingSize = hostingController.view.fittingSize
            if fittingSize.width > 0, fittingSize.height > 0 {
                popover.contentSize = NSSize(
                    width: ceil(fittingSize.width),
                    height: ceil(fittingSize.height)
                )
            }

            popover.show(
                relativeTo: positioningRect(
                    for: anchorView.bounds,
                    preferredEdge: preferredEdge,
                    detachedGap: detachedGap
                ),
                of: anchorView,
                preferredEdge: preferredEdge
            )
        }

        func dismiss() {
            popover?.performClose(nil)
            popover = nil
        }

        func popoverDidClose(_ notification: Notification) {
            popover = nil
            if isPresented {
                isPresented = false
            }
        }

        private func makePopover() -> NSPopover {
            let popover = NSPopover()
            popover.behavior = .semitransient
            popover.animates = true
            popover.setValue(true, forKeyPath: "shouldHideAnchor")
            popover.contentViewController = hostingController
            popover.delegate = self
            self.popover = popover
            return popover
        }

        private func positioningRect(
            for bounds: CGRect,
            preferredEdge: NSRectEdge,
            detachedGap: CGFloat
        ) -> CGRect {
            let hiddenArrowInset: CGFloat = 13
            let compensation = max(hiddenArrowInset - detachedGap, 0)

            switch preferredEdge {
            case .maxY:
                return NSRect(
                    x: bounds.minX,
                    y: bounds.maxY - compensation,
                    width: bounds.width,
                    height: compensation
                )
            case .minY:
                return NSRect(
                    x: bounds.minX,
                    y: bounds.minY,
                    width: bounds.width,
                    height: compensation
                )
            case .maxX:
                return NSRect(
                    x: bounds.maxX - compensation,
                    y: bounds.minY,
                    width: compensation,
                    height: bounds.height
                )
            case .minX:
                return NSRect(
                    x: bounds.minX,
                    y: bounds.minY,
                    width: compensation,
                    height: bounds.height
                )
            @unknown default:
                return bounds
            }
        }
    }
}

private struct SidebarFooterIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SidebarFooterIconButtonStyleBody(configuration: configuration)
    }
}

private struct SidebarFooterIconButtonStyleBody: View {
    let configuration: SidebarFooterIconButtonStyle.Configuration

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    private var backgroundOpacity: Double {
        guard isEnabled else { return 0.0 }
        if configuration.isPressed { return 0.16 }
        if isHovered { return 0.08 }
        return 0.0
    }

    var body: some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(backgroundOpacity))
            )
            .onHover { hovering in
                isHovered = hovering
            }
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

#if DEBUG
private struct SidebarDevFooter: View {
    var updateViewModel: UpdateStateModel
    @ObservedObject var fileExplorerState: FileExplorerState
    let onSendFeedback: () -> Void
    @AppStorage(DevBuildBannerDebugSettings.sidebarBannerVisibleKey)
    private var showSidebarDevBuildBanner = DevBuildBannerDebugSettings.defaultShowSidebarBanner

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SidebarFooterButtons(updateViewModel: updateViewModel, fileExplorerState: fileExplorerState, onSendFeedback: onSendFeedback)
            if showSidebarDevBuildBanner {
                Text(String(localized: "debug.devBuildBanner.title", defaultValue: "THIS IS A DEV BUILD"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.red)
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 10)
        .padding(.bottom, 6)
    }
}
#endif

struct SidebarScrollViewResolver: NSViewRepresentable {
    let onResolve: (NSScrollView?) -> Void

    func makeNSView(context: Context) -> SidebarScrollViewResolverView {
        let view = SidebarScrollViewResolverView()
        view.onResolve = onResolve
        return view
    }

    func updateNSView(_ nsView: SidebarScrollViewResolverView, context: Context) {
        nsView.onResolve = onResolve
        nsView.resolveScrollView()
    }
}

final class SidebarScrollViewResolverView: NSView {
    var onResolve: ((NSScrollView?) -> Void)?

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        resolveScrollView()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        resolveScrollView()
    }

    func resolveScrollView() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            onResolve?(self.enclosingScrollView)
        }
    }
}

struct SidebarEmptyArea: View {
    @EnvironmentObject var tabManager: TabManager
    let rowSpacing: CGFloat
    @Binding var selection: SidebarSelection
    @Binding var selectedTabIds: Set<UUID>
    @Binding var lastSidebarSelectionIndex: Int?
    let dragAutoScrollController: SidebarDragAutoScrollController
    // Value snapshot + closure bundles instead of an @Observable store
    // reference (snapshot-boundary rule).
    let topDropIndicatorVisible: Bool
    let tabDropDelegate: SidebarTabDropDelegate
    let bonsplitDropIndicator: Binding<SidebarDropIndicator?>

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onTapGesture(count: 2) {
                tabManager.addWorkspace(placementOverride: .end)
                if let selectedId = tabManager.selectedTabId {
                    selectedTabIds = [selectedId]
                    lastSidebarSelectionIndex = tabManager.tabs.firstIndex { $0.id == selectedId }
                }
                selection = .tabs
            }
            .onDrop(of: SidebarTabDragPayload.dropContentTypes, delegate: tabDropDelegate)
            .overlay {
                SidebarBonsplitTabNewWorkspaceDropOverlay(
                    tabManager: tabManager,
                    selectedTabIds: $selectedTabIds,
                    lastSidebarSelectionIndex: $lastSidebarSelectionIndex,
                    dropIndicator: bonsplitDropIndicator
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .overlay(alignment: .top) {
                if topDropIndicatorVisible {
                    Rectangle()
                        .fill(cmuxAccentColor())
                        .frame(height: 2)
                        .padding(.horizontal, 8)
                        .offset(y: -(rowSpacing / 2))
                }
            }
    }
}

struct ExtensionSidebarBrowserStackEmptyArea: View {
    let rowSpacing: CGFloat
    let orderedRows: [ExtensionSidebarBrowserStackDropRow]
    let dragAutoScrollController: SidebarDragAutoScrollController
    @Binding var draggedTabId: UUID?
    @Binding var dropIndicator: SidebarDropIndicator?
    let onNewTab: () -> Void
    let onMove: (CmuxSidebarProviderWorkspaceMove) -> Bool

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onTapGesture(count: 2, perform: onNewTab)
            .onDrop(of: SidebarTabDragPayload.dropContentTypes, delegate: ExtensionSidebarBrowserStackEndDropDelegate(
                orderedRows: orderedRows,
                draggedTabId: $draggedTabId,
                dragAutoScrollController: dragAutoScrollController,
                dropIndicator: $dropIndicator,
                onMove: onMove
            ))
            .overlay(alignment: .top) {
                if shouldShowTopDropIndicator {
                    Rectangle()
                        .fill(cmuxAccentColor())
                        .frame(height: 2)
                        .padding(.horizontal, 8)
                        .offset(y: -(rowSpacing / 2))
                }
            }
    }

    private var shouldShowTopDropIndicator: Bool {
        guard let indicator = dropIndicator else { return false }
        if indicator.tabId == nil {
            return true
        }
        guard indicator.edge == .bottom, let lastWorkspaceId = orderedRows.last?.workspaceId else { return false }
        return indicator.tabId == lastWorkspaceId
    }
}

enum SidebarWorkspaceShortcutHintMetrics {
    private static let measurementFont = NSFont.systemFont(ofSize: 10, weight: .semibold)
    private static let minimumSlotWidth: CGFloat = 28
    private static let horizontalPadding: CGFloat = 12
    private static let lock = NSLock()
    private static var cachedHintWidths: [String: CGFloat] = [:]
    #if DEBUG
    private static var measurementCount = 0
    #endif

    static func slotWidth(label: String?, debugXOffset: Double) -> CGFloat {
        guard let label else { return minimumSlotWidth }
        let positiveDebugInset = max(0, CGFloat(ShortcutHintDebugSettings.clamped(debugXOffset))) + 2
        return max(minimumSlotWidth, hintWidth(for: label) + positiveDebugInset)
    }

    static func hintWidth(for label: String) -> CGFloat {
        lock.lock()
        if let cached = cachedHintWidths[label] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let textWidth = (label as NSString).size(withAttributes: [.font: measurementFont]).width
        let measuredWidth = ceil(textWidth) + horizontalPadding

        lock.lock()
        cachedHintWidths[label] = measuredWidth
        #if DEBUG
        measurementCount += 1
        #endif
        lock.unlock()
        return measuredWidth
    }

    #if DEBUG
    static func resetCacheForTesting() {
        lock.lock()
        cachedHintWidths.removeAll()
        measurementCount = 0
        lock.unlock()
    }

    static func measurementCountForTesting() -> Int {
        lock.lock()
        let count = measurementCount
        lock.unlock()
        return count
    }
    #endif
}

enum SidebarTrailingAccessoryWidthPolicy {
    static let closeButtonWidth: CGFloat = 16
}
