import AppKit
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

enum DevBuildBannerDebugSettings {
    static let sidebarBannerVisibleKey = "showSidebarDevBuildBanner"
    static let defaultShowSidebarBanner = true

    static func showSidebarBanner(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: sidebarBannerVisibleKey) != nil else {
            return defaultShowSidebarBanner
        }
        return defaults.bool(forKey: sidebarBannerVisibleKey)
    }
}

private enum FeedbackComposerSettings {
    static let storedEmailKey = "sidebarHelpFeedbackEmail"
    static let endpointEnvironmentKey = "CMUX_FEEDBACK_API_URL"
    static let defaultEndpoint = "https://cmux.com/api/feedback"
    static let foundersEmail = "founders@manaflow.com"
    static let maxMessageLength = 4_000
    static let maxAttachmentCount = 10
    // Keep the multipart body below Vercel's 4.5 MB request limit.
    static let maxTotalAttachmentBytes = 4 * 1_024 * 1_024
    static let targetTotalAttachmentUploadBytes = 3_500_000

    static func endpointURL() -> URL? {
        let env = ProcessInfo.processInfo.environment
        if let override = env[endpointEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return URL(string: override)
        }
        return URL(string: defaultEndpoint)
    }
}

private struct FeedbackComposerAttachment: Identifiable {
    let id = UUID()
    let url: URL
    let fileName: String
    let fileSize: Int64
    let mimeType: String

    var standardizedPath: String {
        url.standardizedFileURL.path
    }

    var displaySize: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    init(url: URL) throws {
        let resourceValues = try url.resourceValues(forKeys: [
            .contentTypeKey,
            .fileSizeKey,
            .isRegularFileKey,
            .nameKey,
        ])
        guard resourceValues.isRegularFile != false else {
            throw CocoaError(.fileReadUnknown)
        }

        self.url = url
        self.fileName = resourceValues.name ?? url.lastPathComponent
        self.fileSize = Int64(resourceValues.fileSize ?? 0)
        self.mimeType = resourceValues.contentType?.preferredMIMEType ?? "application/octet-stream"
    }
}

private struct PreparedFeedbackComposerAttachment {
    let fileName: String
    let mimeType: String
    let data: Data
}

private struct FeedbackComposerAppMetadata {
    let appVersion: String
    let appBuild: String
    let appCommit: String
    let bundleIdentifier: String
    let osVersion: String
    let localeIdentifier: String
    let hardwareModel: String
    let chip: String
    let memoryGB: String
    let architecture: String
    let displayInfo: String

    static var current: FeedbackComposerAppMetadata {
        let infoDictionary = Bundle.main.infoDictionary ?? [:]
        let env = ProcessInfo.processInfo.environment
        let commit = (infoDictionary["CMUXCommit"] as? String).flatMap { value in
            value.isEmpty ? nil : value
        } ?? env["CMUX_COMMIT"]

        return FeedbackComposerAppMetadata(
            appVersion: infoDictionary["CFBundleShortVersionString"] as? String ?? "",
            appBuild: infoDictionary["CFBundleVersion"] as? String ?? "",
            appCommit: commit ?? "",
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            localeIdentifier: Locale.preferredLanguages.first ?? Locale.current.identifier,
            hardwareModel: sysctlString("hw.model") ?? "",
            chip: sysctlString("machdep.cpu.brand_string") ?? "",
            memoryGB: formatMemoryGB(),
            architecture: currentArchitecture(),
            displayInfo: currentDisplayInfo()
        )
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func formatMemoryGB() -> String {
        let bytes = ProcessInfo.processInfo.physicalMemory
        let gb = Double(bytes) / (1024 * 1024 * 1024)
        return "\(Int(gb)) GB"
    }

    private static func currentArchitecture() -> String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    private static func currentDisplayInfo() -> String {
        let screens = NSScreen.screens
        let descriptions = screens.map { screen -> String in
            let frame = screen.frame
            let scale = screen.backingScaleFactor
            return "\(Int(frame.width))x\(Int(frame.height)) @\(Int(scale))x"
        }
        let count = screens.count
        let prefix = "\(count) display\(count == 1 ? "" : "s")"
        return "\(prefix), \(descriptions.joined(separator: "; "))"
    }
}

private enum FeedbackComposerSubmissionError: Error {
    case invalidEndpoint
    case invalidResponse
    case rejected(statusCode: Int)
    case attachmentReadFailed
    case attachmentPreparationFailed
    case transport(URLError)
}

private enum FeedbackComposerClient {
    private static let passthroughAttachmentMIMETypes: Set<String> = [
        "image/gif",
        "image/heic",
        "image/heif",
        "image/jpeg",
        "image/png",
        "image/tiff",
        "image/webp",
    ]
    private static let optimizedAttachmentDimensions: [Int] = [2800, 2400, 2000, 1600, 1280, 1024, 768, 640, 512]
    private static let optimizedAttachmentQualities: [CGFloat] = [0.82, 0.72, 0.62, 0.52, 0.42, 0.32]
    private static let optimizedAttachmentMIMEType = "image/jpeg"

    static func submit(
        email: String,
        message: String,
        attachments: [FeedbackComposerAttachment]
    ) async throws {
        guard let endpointURL = FeedbackComposerSettings.endpointURL() else {
            throw FeedbackComposerSubmissionError.invalidEndpoint
        }

        let metadata = FeedbackComposerAppMetadata.current
        let boundary = "Boundary-\(UUID().uuidString)"
        let preparedAttachments = try prepareAttachmentsForUpload(attachments)

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        var body = Data()
        appendField("email", value: email, to: &body, boundary: boundary)
        appendField("message", value: message, to: &body, boundary: boundary)
        appendField("appVersion", value: metadata.appVersion, to: &body, boundary: boundary)
        appendField("appBuild", value: metadata.appBuild, to: &body, boundary: boundary)
        appendField("appCommit", value: metadata.appCommit, to: &body, boundary: boundary)
        appendField("bundleIdentifier", value: metadata.bundleIdentifier, to: &body, boundary: boundary)
        appendField("osVersion", value: metadata.osVersion, to: &body, boundary: boundary)
        appendField("locale", value: metadata.localeIdentifier, to: &body, boundary: boundary)
        appendField("hardwareModel", value: metadata.hardwareModel, to: &body, boundary: boundary)
        appendField("chip", value: metadata.chip, to: &body, boundary: boundary)
        appendField("memoryGB", value: metadata.memoryGB, to: &body, boundary: boundary)
        appendField("architecture", value: metadata.architecture, to: &body, boundary: boundary)
        appendField("displayInfo", value: metadata.displayInfo, to: &body, boundary: boundary)

        for attachment in preparedAttachments {
            appendFile(
                named: "attachments",
                attachment: attachment,
                to: &body,
                boundary: boundary
            )
        }

        body.append(Data("--\(boundary)--\r\n".utf8))
        request.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError {
            throw FeedbackComposerSubmissionError.transport(error)
        } catch {
            throw FeedbackComposerSubmissionError.invalidResponse
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw FeedbackComposerSubmissionError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            if let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errorMessage = payload["error"] as? String,
               errorMessage.isEmpty == false {
                NSLog("feedback.submit.rejected status=%@ error=%@", String(httpResponse.statusCode), errorMessage)
            }
            throw FeedbackComposerSubmissionError.rejected(statusCode: httpResponse.statusCode)
        }
    }

    private static func appendField(
        _ name: String,
        value: String,
        to body: inout Data,
        boundary: String
    ) {
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
        body.append(Data(value.utf8))
        body.append(Data("\r\n".utf8))
    }

    private static func prepareAttachmentsForUpload(
        _ attachments: [FeedbackComposerAttachment]
    ) throws -> [PreparedFeedbackComposerAttachment] {
        guard attachments.isEmpty == false else { return [] }

        struct IndexedAttachment {
            let index: Int
            let attachment: FeedbackComposerAttachment
        }

        let sortedAttachments = attachments.enumerated()
            .map { IndexedAttachment(index: $0.offset, attachment: $0.element) }
            .sorted { lhs, rhs in
                lhs.attachment.fileSize > rhs.attachment.fileSize
            }

        var preparedByIndex: [Int: PreparedFeedbackComposerAttachment] = [:]
        var remainingBudget = FeedbackComposerSettings.targetTotalAttachmentUploadBytes
        var remainingCount = sortedAttachments.count

        for item in sortedAttachments {
            let perAttachmentBudget = max(1, remainingBudget / max(remainingCount, 1))
            let preparedAttachment = try prepareAttachmentForUpload(
                item.attachment,
                maximumByteCount: perAttachmentBudget
            )
            preparedByIndex[item.index] = preparedAttachment
            remainingBudget -= preparedAttachment.data.count
            remainingCount -= 1
        }

        let preparedAttachments = attachments.indices.compactMap { preparedByIndex[$0] }
        let totalBytes = preparedAttachments.reduce(0) { $0 + $1.data.count }
        guard totalBytes <= FeedbackComposerSettings.targetTotalAttachmentUploadBytes else {
            throw FeedbackComposerSubmissionError.attachmentPreparationFailed
        }
        return preparedAttachments
    }

    private static func prepareAttachmentForUpload(
        _ attachment: FeedbackComposerAttachment,
        maximumByteCount: Int
    ) throws -> PreparedFeedbackComposerAttachment {
        if attachment.fileSize > 0,
           attachment.fileSize <= Int64(maximumByteCount),
           passthroughAttachmentMIMETypes.contains(attachment.mimeType),
           let fileData = try? Data(contentsOf: attachment.url, options: .mappedIfSafe) {
            return PreparedFeedbackComposerAttachment(
                fileName: attachment.fileName,
                mimeType: attachment.mimeType,
                data: fileData
            )
        }

        guard let imageSource = CGImageSourceCreateWithURL(attachment.url as CFURL, nil) else {
            throw FeedbackComposerSubmissionError.attachmentReadFailed
        }

        for maxPixelDimension in optimizedAttachmentDimensions {
            guard let cgImage = downsampledImage(
                from: imageSource,
                maxPixelDimension: maxPixelDimension
            ) else { continue }

            for compressionQuality in optimizedAttachmentQualities {
                guard let jpegData = jpegData(
                    from: cgImage,
                    compressionQuality: compressionQuality
                ) else { continue }
                guard jpegData.count <= maximumByteCount else { continue }

                return PreparedFeedbackComposerAttachment(
                    fileName: optimizedFileName(for: attachment),
                    mimeType: optimizedAttachmentMIMEType,
                    data: jpegData
                )
            }
        }

        throw FeedbackComposerSubmissionError.attachmentPreparationFailed
    }

    private static func downsampledImage(
        from imageSource: CGImageSource,
        maxPixelDimension: Int
    ) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(
            imageSource,
            0,
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCache: false,
                kCGImageSourceShouldCacheImmediately: false,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelDimension,
            ] as CFDictionary
        )
    }

    private static func jpegData(
        from image: CGImage,
        compressionQuality: CGFloat
    ) -> Data? {
        let bitmap = NSBitmapImageRep(cgImage: image)
        return bitmap.representation(
            using: .jpeg,
            properties: [
                .compressionFactor: compressionQuality,
            ]
        )
    }

    private static func optimizedFileName(
        for attachment: FeedbackComposerAttachment
    ) -> String {
        let baseName = (attachment.fileName as NSString).deletingPathExtension
        return "\(baseName.isEmpty ? "feedback-image" : baseName).jpg"
    }

    private static func appendFile(
        named fieldName: String,
        attachment: PreparedFeedbackComposerAttachment,
        to body: inout Data,
        boundary: String
    ) {
        let sanitizedFileName = attachment.fileName.replacingOccurrences(of: "\"", with: "")

        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(
            Data(
                "Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(sanitizedFileName)\"\r\n".utf8
            )
        )
        body.append(Data("Content-Type: \(attachment.mimeType)\r\n\r\n".utf8))
        body.append(attachment.data)
        body.append(Data("\r\n".utf8))
    }
}

struct SidebarFooter: View {
    @ObservedObject var updateViewModel: UpdateViewModel
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
    @ObservedObject var updateViewModel: UpdateViewModel
    @ObservedObject var fileExplorerState: FileExplorerState
    let onSendFeedback: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            SidebarHelpMenuButton(onSendFeedback: onSendFeedback)
            UpdatePill(model: updateViewModel)
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

private final class FeedbackComposerMessageScrollView: NSScrollView {
    weak var focusTextView: NSTextView?

    override func mouseDown(with event: NSEvent) {
        if let focusTextView {
            _ = window?.makeFirstResponder(focusTextView)
        }
        super.mouseDown(with: event)
    }
}

private final class FeedbackComposerMessageEditorView: NSView {
    private static let textInset = NSSize(width: 10, height: 10)

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
        scrollView.hasVerticalScroller = true
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
        textView.font = .systemFont(ofSize: 12)
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.textContainerInset = Self.textInset
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )

        scrollView.documentView = textView
        addSubview(scrollView)

        placeholderField.translatesAutoresizingMaskIntoConstraints = false
        placeholderField.font = .systemFont(ofSize: 12)
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
        updatePlaceholderVisibility()
    }

    private func updatePlaceholderVisibility() {
        placeholderField.isHidden = textView.string.isEmpty == false
    }

    private func syncTextViewFrameToContentSize() {
        let contentSize = scrollView.contentSize
        guard contentSize.width > 0, contentSize.height > 0 else { return }

        textView.minSize = NSSize(width: 0, height: contentSize.height)
        textView.textContainer?.containerSize = NSSize(
            width: contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )

        let targetSize = NSSize(
            width: contentSize.width,
            height: max(textView.frame.height, contentSize.height)
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
                formView
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
    @ObservedObject var updateViewModel: UpdateViewModel
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
