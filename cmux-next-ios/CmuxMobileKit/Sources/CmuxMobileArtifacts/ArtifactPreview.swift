#if os(iOS)
import AVKit
import CmuxMobileDesign
import PDFKit
import QuickLook
import SwiftUI
import WebKit

/// The best preview for each kind: rendered HTML and Markdown with a Source
/// toggle, syntax-colored code, zoomable images, a video player, PDFs, web
/// links, folder listings. Folder rows push `TerminalArtifact` values, so the
/// enclosing stack registers `navigationDestination(for: TerminalArtifact.self)`.
public struct ArtifactPreview: View {
    let artifact: TerminalArtifact
    let source: any ArtifactSource
    @Binding var showSource: Bool
    @State private var content: Result<ArtifactContent, any Error>?
    /// Bumped by Try Again: reloads the artifact.
    @State private var attempt = 0
    /// A local file (or the link) Share hands to the share sheet: Save to
    /// Files, Save Image, AirDrop, Open In.
    @State private var shareItem: URL?
    /// A downward drag on an image at its fitted size (closes a full-screen preview).
    @State private var dismissDrag: CGFloat = 0
    @Environment(\.openURL) private var openURL
    /// Shown as a Close button when the preview is full screen (a file tapped in a
    /// chat or composer), not pushed in a browser.
    let onClose: (() -> Void)?
    /// "2 of 5" under the name, when the preview pages through several files.
    let position: (index: Int, count: Int)?

    public init(artifact: TerminalArtifact, source: any ArtifactSource, showSource: Binding<Bool>,
                position: (index: Int, count: Int)? = nil, onClose: (() -> Void)? = nil) {
        self.artifact = artifact
        self.source = source
        _showSource = showSource
        self.position = position
        self.onClose = onClose
    }

    private var rendersAsWeb: Bool { artifact.kind == .html || artifact.kind == .markdown }

    /// Accessibility identifier of the view shown when the Mac refuses the
    /// file (or it can't be read): the E2E rig's non-blank end state.
    public static let refusedIdentifier = "artifacts.preview.refused"
    /// Accessibility identifier of the view shown for an empty file.
    public static let emptyIdentifier = "artifacts.preview.empty"

    /// Nothing to preview (refused, unreadable, empty): no Preview/Source
    /// toggle and no content actions, only Copy Path (design/terminal M7).
    private var isDeadEnd: Bool {
        switch content {
        case .failure: true
        case .success(let loaded): loaded.isEmptyFile
        case nil: false
        }
    }

    /// The loaded content wants the whole screen (images and videos, P4).
    private var wantsLargeSheet: Bool {
        switch content {
        case .success(.image), .success(.file), .success(.quickLook): true
        default: false
        }
    }

    public var body: some View {
        Group {
            switch content {
            case nil:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("artifact.loading")
            case .failure(let error):
                // Never a blank page: what the Mac said, and a way to try again.
                ArtifactDeadEnd(
                    headline: artifact.kind == .directory ? "Can't open this folder" : "Can't open this file",
                    systemImage: "exclamationmark.triangle", name: artifact.name, message: error.localizedDescription
                ) {
                    Button("Try Again") {
                        content = nil
                        attempt += 1
                    }
                    .accessibilityIdentifier("artifact.retry")
                }
                .accessibilityIdentifier(Self.refusedIdentifier)
            case .success(let loaded) where loaded.isEmptyFile:
                ArtifactDeadEnd(headline: "This file is empty", systemImage: artifact.systemImage, name: artifact.name, message: nil) {
                    EmptyView()
                }
                .accessibilityIdentifier(Self.emptyIdentifier)
            case .success(let loaded):
                view(for: loaded)
            }
        }
        .navigationTitle(artifact.name)
        .navigationBarTitleDisplayMode(.inline)
        .background {
            if wantsLargeSheet { SheetDetentExpander() }
        }
        .toolbar {
            // The name truncates in the middle, so its extension stays visible.
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(artifact.name)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityAddTraits(.isHeader)
                    if let position, position.count > 1 {
                        Text("\(position.index + 1) of \(position.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("artifact.position")
                    }
                }
            }
            if let onClose {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close", systemImage: "xmark", action: onClose)
                        .accessibilityIdentifier("artifact.close")
                }
            }
            if rendersAsWeb, !isDeadEnd {
                ToolbarItem(placement: .topBarTrailing) {
                    Picker("View", selection: $showSource) {
                        Image(systemName: "eye").tag(false).accessibilityLabel("Preview")
                        Image(systemName: "chevron.left.forwardslash.chevron.right").tag(true).accessibilityLabel("Source")
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 110)
                    .accessibilityIdentifier("artifact.sourceToggle")
                }
            }
            if artifact.kind == .link, let url = URL(string: artifact.reference) {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Open in Safari", systemImage: "safari") { openURL(url) }
                }
            }
            if content != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if !isDeadEnd, let shareItem {
                            // Save to Files, Save Image, AirDrop and Open In live in the share sheet.
                            ShareLink(item: shareItem, preview: SharePreview(artifact.name)) {
                                Label("Share or Save", systemImage: "square.and.arrow.up")
                            }
                        }
                        if !artifact.reference.hasPrefix(LocalFileArtifactSource.scheme) {
                            Button("Copy Path", systemImage: "doc.on.doc") { UIPasteboard.general.string = artifact.reference }
                        }
                        if !isDeadEnd, case .success(.text(let text)) = content {
                            Button("Copy Contents", systemImage: "text.document") { UIPasteboard.general.string = text }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel("More")
                }
            }
        }
        .task(id: ArtifactLoad(artifact: artifact, attempt: attempt)) {
            do {
                let loaded = try await source.load(artifact)
                content = .success(loaded)
                // The share copy (up to the preview limit) is written off the main actor.
                let artifact = artifact
                shareItem = await Task.detached(priority: .utility) { Self.shareItem(for: loaded, artifact: artifact) }.value
            } catch {
                content = .failure(error)
                shareItem = nil
            }
        }
        .offset(y: dismissDrag)
    }

    @ViewBuilder
    private func view(for content: ArtifactContent) -> some View {
        switch content {
        case .text(let text):
            if artifact.kind == .html, !showSource {
                WebPreview(mode: .html(artifact.fileExtension == "svg" ? TerminalArtifact.fittedSVG(text) : text))
            } else if artifact.kind == .markdown, !showSource {
                WebPreview(mode: .html(MarkdownHTML.render(text)))
            } else {
                CodeView(text: text, language: artifact.kind == .html ? "html" : artifact.kind == .markdown ? "md" : artifact.fileExtension,
                         highlightLine: artifact.line)
            }
        case .image(let data):
            ZoomableImage(image: UIImage(data: data), label: "Image, \(artifact.name)", onDismissDrag: onClose.map { close in
                { translation, ended in
                    if ended {
                        if translation > 120 { close() } else { withAnimation(.cmuxMobileSnap) { dismissDrag = 0 } }
                    } else {
                        dismissDrag = max(0, translation)
                    }
                }
            })
        case .file(let url):
            AutoplayVideo(url: url)
        case .quickLook(let url):
            if QuickLookPreview.canPreview(url) {
                QuickLookPreview(url: url)
                    .ignoresSafeArea(edges: .bottom)
                    .accessibilityIdentifier("artifact.quickLook")
            } else {
                // Nothing on the phone shows this type: hand it to another app.
                ArtifactDeadEnd(headline: "No preview for this file", systemImage: artifact.systemImage, name: artifact.name,
                                message: Self.sizeLine(url)) {
                    ShareLink(item: url, preview: SharePreview(artifact.name)) {
                        Label("Share or Open In…", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("artifact.share")
                }
                .accessibilityIdentifier("artifact.unpreviewable")
            }
        case .web(let url):
            WebPreview(mode: .url(url))
        case .pdf(let data):
            PDFPreview(data: data)
        case .directory(let children):
            List(children) { child in
                NavigationLink(value: child) { ArtifactRow(artifact: child) }
            }
            .listStyle(.plain)
        case .binary(let description):
            ContentUnavailableView {
                Label {
                    Text(artifact.name).lineLimit(1).truncationMode(.middle)
                } icon: {
                    Image(systemName: artifact.systemImage)
                }
            } description: {
                Text(description).font(.footnote.monospaced())
            }
        }
    }

    /// What Share hands over: the loaded file under its own name (images, PDFs and
    /// text get a local copy), the page for a link; nothing for folders.
    nonisolated static func shareItem(for content: ArtifactContent, artifact: TerminalArtifact) -> URL? {
        switch content {
        case .file(let url), .quickLook(let url): return url
        case .web(let url): return url
        case .image(let data), .pdf(let data): return try? ArtifactLocalCopy.write(data, for: artifact)
        case .text(let text): return try? ArtifactLocalCopy.write(Data(text.utf8), for: artifact)
        case .directory, .binary: return nil
        }
    }

    nonisolated static func sizeLine(_ url: URL) -> String? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}

/// QLPreviewController for one local file (audio, Office and iWork, RTF, and
/// anything else Quick Look renders), embedded in the preview page.
struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    static func canPreview(_ url: URL) -> Bool { QLPreviewController.canPreview(url as NSURL) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        guard context.coordinator.url != url else { return }
        context.coordinator.url = url
        controller.reloadData()
    }

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL
        init(url: URL) { self.url = url }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem { url as NSURL }
    }
}

/// A preview with nothing to show (refused, unreadable, empty): a short
/// headline, the file name on its own line (middle truncation, never
/// hyphen-wrapped), why, and an optional action. One accessibility
/// container, so its identifier reaches the rig and VoiceOver reads it in order.
struct ArtifactDeadEnd<Actions: View>: View {
    let headline: String
    let systemImage: String
    let name: String
    let message: String?
    @ViewBuilder let actions: Actions

    var body: some View {
        ContentUnavailableView {
            Label(headline, systemImage: systemImage)
        } description: {
            VStack(spacing: 6) {
                Text(name)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let message {
                    Text(message)
                }
            }
        } actions: {
            actions
        }
        .accessibilityElement(children: .contain)
    }
}

/// Moves the enclosing sheet to its large detent when it appears (images
/// and videos fill the screen, design/terminal P4). Does nothing outside a
/// sheet, or for a sheet without a large detent.
struct SheetDetentExpander: UIViewRepresentable {
    func makeUIView(context: Context) -> ExpanderView { ExpanderView() }
    func updateUIView(_ view: ExpanderView, context: Context) {}

    final class ExpanderView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            var responder: UIResponder? = next
            while let current = responder, !(current is UIViewController) { responder = current.next }
            var controller = responder as? UIViewController
            while let current = controller {
                if let sheet = current.sheetPresentationController {
                    guard sheet.detents.contains(where: { $0.identifier == .large }), sheet.selectedDetentIdentifier != .large else { return }
                    sheet.animateChanges { sheet.selectedDetentIdentifier = .large }
                    return
                }
                controller = current.parent
            }
        }
    }
}

/// What `ArtifactPreview` loads: the artifact, again for each Try Again.
private struct ArtifactLoad: Hashable {
    let artifact: TerminalArtifact
    let attempt: Int
}

/// A video that starts playing when it opens (system controls on tap).
struct AutoplayVideo: View {
    let url: URL
    @State private var player: AVPlayer?

    var body: some View {
        VideoPlayer(player: player)
            .background(.black)
            .onAppear {
                let player = AVPlayer(url: url)
                self.player = player
                player.play()
            }
            .onDisappear { player?.pause() }
    }
}

/// PDFKit with continuous vertical pages.
struct PDFPreview: UIViewRepresentable {
    let data: Data

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayDirection = .vertical
        view.backgroundColor = .secondarySystemBackground
        view.document = PDFDocument(data: data)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {}
}

/// WKWebView for HTML artifacts (JavaScript off) and links.
public struct WebPreview: UIViewRepresentable {
    public enum Mode: Equatable { case html(String), url(URL) }
    let mode: Mode

    public init(mode: Mode) { self.mode = mode }

    public func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        if case .html = mode {
            configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        }
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.isOpaque = false
        web.backgroundColor = .systemBackground
        web.scrollView.contentInsetAdjustmentBehavior = .automatic
        load(web)
        context.coordinator.mode = mode
        return web
    }

    public func updateUIView(_ web: WKWebView, context: Context) {
        guard context.coordinator.mode != mode else { return }
        context.coordinator.mode = mode
        load(web)
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public final class Coordinator { var mode: Mode? }

    private func load(_ web: WKWebView) {
        switch mode {
        case .html(let html): web.loadHTMLString(html, baseURL: nil)
        case .url(let url): web.load(URLRequest(url: url))
        }
    }
}

/// Pinch and double-tap zoom (artifact previews and the chat's full-screen image viewer).
public struct ZoomableImage: View {
    let image: UIImage?
    let label: String
    @State private var zoom = ZoomControl()
    var onZoomChange: ((Bool) -> Void)?
    var onDismissDrag: ((CGFloat, Bool) -> Void)?

    /// `onZoomChange`: zoomed in or back at the fitted size. `onDismissDrag`: a downward
    /// drag at the fitted size (translation, ended), for a swipe-to-dismiss host.
    public init(image: UIImage?, label: String = "Image",
                onZoomChange: ((Bool) -> Void)? = nil, onDismissDrag: ((CGFloat, Bool) -> Void)? = nil) {
        self.image = image
        self.label = label
        self.onZoomChange = onZoomChange
        self.onDismissDrag = onDismissDrag
    }

    public var body: some View {
        if let image {
            ZoomingImageView(image: image, label: label, control: zoom, onZoomChange: onZoomChange, onDismissDrag: onDismissDrag)
                .background(Color.black)
                // One labelled image for VoiceOver, with zoom as an action.
                .accessibilityElement()
                .accessibilityLabel(Text(label))
                .accessibilityAddTraits(.isImage)
                .accessibilityAction(named: Text("Zoom in or fit")) { zoom.view?.toggleZoomAtCenter() }
                #if DEBUG
                // `-cmux-mobile-image-zoom-demo`: double-tap's zoom path at launch (simulator HID
                // double-taps do not reach the viewer).
                .task {
                    guard CommandLine.arguments.contains("-cmux-mobile-image-zoom-demo") else { return }
                    try? await Task.sleep(for: .seconds(1))
                    zoom.view?.toggleZoom(at: CGPoint(x: 60, y: 60))
                }
                #endif
        } else {
            ContentUnavailableView("Not an image", systemImage: "photo")
        }
    }
}

/// Pinch, double-tap to zoom to the tapped point, pan while zoomed (a `UIScrollView`
/// zoom host), and a downward drag reported only at the fitted size.
/// Reaches the zoom view from SwiftUI (accessibility action, DEBUG demo).
@MainActor
final class ZoomControl {
    weak var view: ZoomingImageScrollView?
}

struct ZoomingImageView: UIViewRepresentable {
    let image: UIImage
    let label: String
    let control: ZoomControl
    var onZoomChange: ((Bool) -> Void)?
    var onDismissDrag: ((CGFloat, Bool) -> Void)?

    func makeUIView(context: Context) -> ZoomingImageScrollView {
        let view = ZoomingImageScrollView()
        update(view)
        return view
    }

    func updateUIView(_ view: ZoomingImageScrollView, context: Context) {
        update(view)
    }

    private func update(_ view: ZoomingImageScrollView) {
        control.view = view
        view.onZoomChange = onZoomChange
        view.onDismissDrag = onDismissDrag
        view.set(image: image, label: label)
    }
}

final class ZoomingImageScrollView: UIScrollView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    let imageView = UIImageView()
    let geometry = ZoomGeometry()
    var onZoomChange: ((Bool) -> Void)?
    var onDismissDrag: ((CGFloat, Bool) -> Void)?
    private var wasZoomed = false
    private var fittedFor: CGSize = .zero
    private lazy var dismissPan = UIPanGestureRecognizer(target: self, action: #selector(dismissPanned(_:)))

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        minimumZoomScale = geometry.minimumScale
        maximumZoomScale = geometry.maximumScale
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        decelerationRate = .fast
        backgroundColor = .black
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        imageView.isAccessibilityElement = true
        imageView.accessibilityTraits = [.image]
        addSubview(imageView)
        // The scroll view is a container whose one element is the labelled image.
        isAccessibilityElement = false
        accessibilityElements = [imageView]
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
        dismissPan.delegate = self
        addGestureRecognizer(dismissPan)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func set(image: UIImage, label: String) {
        if imageView.image !== image {
            imageView.image = image
            fittedFor = .zero
            setNeedsLayout()
        }
        imageView.accessibilityLabel = label
        imageView.accessibilityHint = geometry.isZoomed(zoomScale) ? "Zoomed in. Double-tap to fit." : "Double-tap to zoom."
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != .zero, let image = imageView.image, image.size.width > 0 else { return }
        if fittedFor != bounds.size {
            // The image fitted to the viewport at scale 1.
            fittedFor = bounds.size
            setZoomScale(minimumZoomScale, animated: false)
            let ratio = min(bounds.width / image.size.width, bounds.height / image.size.height)
            let fitted = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
            imageView.frame = CGRect(origin: .zero, size: fitted)
            contentSize = fitted
        }
        center()
    }

    private func center() {
        let insets = geometry.centeringInsets(content: imageView.frame.size, viewport: bounds.size)
        contentInset = UIEdgeInsets(top: insets.vertical, left: insets.horizontal, bottom: insets.vertical, right: insets.horizontal)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        center()
        let zoomed = geometry.isZoomed(zoomScale)
        if zoomed != wasZoomed {
            wasZoomed = zoomed
            imageView.accessibilityHint = zoomed ? "Zoomed in. Double-tap to fit." : "Double-tap to zoom."
            onZoomChange?(zoomed)
        }
    }

    @objc func doubleTapped(_ recognizer: UITapGestureRecognizer) {
        toggleZoom(at: recognizer.location(in: imageView))
    }

    /// Double-tap: zoom to `ZoomGeometry.doubleTapScale` around the point, or back to fit.
    func toggleZoom(at point: CGPoint) {
        if let target = geometry.doubleTapTarget(scale: zoomScale, tap: point, viewSize: bounds.size) {
            zoom(to: target, animated: true)
        } else {
            setZoomScale(minimumZoomScale, animated: true)
        }
    }

    func toggleZoomAtCenter() {
        toggleZoom(at: CGPoint(x: imageView.bounds.midX, y: imageView.bounds.midY))
    }

    // MARK: Swipe to dismiss (fitted size only)

    override func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard recognizer === dismissPan else { return super.gestureRecognizerShouldBegin(recognizer) }
        guard onDismissDrag != nil, !geometry.isZoomed(zoomScale) else { return false }
        let velocity = dismissPan.velocity(in: self)
        return velocity.y > 0 && abs(velocity.y) > abs(velocity.x)
    }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        false
    }

    @objc private func dismissPanned(_ recognizer: UIPanGestureRecognizer) {
        let translation = max(0, recognizer.translation(in: self).y)
        switch recognizer.state {
        case .changed: onDismissDrag?(translation, false)
        case .ended, .cancelled, .failed: onDismissDrag?(translation, true)
        default: break
        }
    }

    // MARK: Accessibility

    override func accessibilityPerformMagicTap() -> Bool {
        toggleZoom(at: CGPoint(x: imageView.bounds.midX, y: imageView.bounds.midY))
        return true
    }
}

/// Code with a line-number gutter and syntax colors (SPEC 11.4 CodeView).
struct CodeView: View {
    let text: String
    let language: String
    var highlightLine: Int?
    @State private var wrap = false

    var body: some View {
        let lines = text.components(separatedBy: "\n")
        ScrollViewReader { proxy in
            ScrollView(wrap ? .vertical : [.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        HStack(alignment: .firstTextBaseline, spacing: 0) {
                            Text("\(index + 1)")
                                .foregroundStyle(.tertiary)
                                .frame(width: 40, alignment: .trailing)
                                .padding(.trailing, 12)
                            Text(SyntaxHighlighter.highlight(line, language: language))
                                .fixedSize(horizontal: !wrap, vertical: true)
                        }
                        .font(.system(size: 13, design: .monospaced))
                        .padding(.vertical, 1)
                        .background(index + 1 == highlightLine ? Color.yellow.opacity(0.15) : .clear)
                        .id(index + 1)
                    }
                }
                .padding(.vertical, 12)
                .padding(.trailing, 16)
                .textSelection(.enabled)
            }
            .defaultScrollAnchor(.topLeading)
            .onAppear { if let highlightLine { proxy.scrollTo(highlightLine, anchor: .center) } }
        }
        .background(Color(uiColor: .secondarySystemBackground))
        .toolbar {
            ToolbarItem(placement: .bottomBar) {
                Toggle(isOn: $wrap) { Label("Wrap lines", systemImage: "text.word.spacing") }
            }
        }
    }
}

/// A small tokenizer: comments, strings, numbers, keywords, types, HTML tags.
struct SyntaxHighlighter {
    static let keywordColor = Color(red: 0.99, green: 0.37, blue: 0.64)
    static let stringColor = Color(red: 0.99, green: 0.42, blue: 0.36)
    static let commentColor = Color(red: 0.42, green: 0.47, blue: 0.53)
    static let numberColor = Color(red: 0.82, green: 0.75, blue: 0.43)
    static let typeColor = Color(red: 0.36, green: 0.85, blue: 0.95)
    static let tagColor = Color(red: 0.36, green: 0.85, blue: 0.95)

    static let keywords: Set<String> = [
        "func", "let", "var", "if", "else", "for", "while", "return", "import", "struct", "class", "enum", "case",
        "switch", "match", "fn", "pub", "use", "impl", "mut", "self", "Self", "static", "public", "private", "true",
        "false", "nil", "None", "Some", "async", "await", "try", "guard", "in", "where", "const", "type", "def",
        "from", "export", "function", "new", "package", "name", "version", "edition", "mod", "crate", "as",
    ]

    static func highlight(_ line: String, language: String) -> AttributedString {
        var result = AttributedString(line)
        guard !line.isEmpty else { return result }
        let commentPrefix = ["py", "sh", "toml", "yml", "yaml", "rb"].contains(language) ? "#" : "//"
        if language == "html" || language == "md" {
            return highlightMarkup(line, language: language)
        }
        let characters = Array(line)
        var index = 0
        func color(_ start: Int, _ end: Int, _ color: Color) {
            let lower = result.index(result.startIndex, offsetByCharacters: start)
            let upper = result.index(result.startIndex, offsetByCharacters: end)
            result[lower..<upper].foregroundColor = color
        }
        while index < characters.count {
            let rest = String(characters[index...])
            if rest.hasPrefix(commentPrefix) || rest.hasPrefix("///") {
                color(index, characters.count, commentColor)
                break
            }
            let character = characters[index]
            if character == "\"" || character == "'" && language != "rs" {
                var end = index + 1
                while end < characters.count, characters[end] != character {
                    end += characters[end] == "\\" ? 2 : 1
                }
                end = min(end + 1, characters.count)
                color(index, end, stringColor)
                index = end
            } else if character.isNumber {
                var end = index
                while end < characters.count, characters[end].isNumber || characters[end] == "." || characters[end] == "_" { end += 1 }
                color(index, end, numberColor)
                index = end
            } else if character.isLetter || character == "_" || character == "#" || character == "@" {
                var end = index + 1
                while end < characters.count, characters[end].isLetter || characters[end].isNumber || characters[end] == "_" { end += 1 }
                let word = String(characters[index..<end])
                if keywords.contains(word) || word.hasPrefix("#") || word.hasPrefix("@") {
                    color(index, end, keywordColor)
                } else if let first = word.first, first.isUppercase {
                    color(index, end, typeColor)
                }
                index = end
            } else {
                index += 1
            }
        }
        return result
    }

    private static func highlightMarkup(_ line: String, language: String) -> AttributedString {
        var result = AttributedString(line)
        if language == "md" {
            if line.hasPrefix("#") { result.foregroundColor = keywordColor }
            else if line.hasPrefix("```") || line.hasPrefix("    ") { result.foregroundColor = stringColor }
            else if line.hasPrefix(">") { result.foregroundColor = commentColor }
            return result
        }
        let characters = Array(line)
        var index = 0
        while index < characters.count {
            if characters[index] == "<" {
                var end = index
                while end < characters.count, characters[end] != ">" { end += 1 }
                end = min(end + 1, characters.count)
                let lower = result.index(result.startIndex, offsetByCharacters: index)
                let upper = result.index(result.startIndex, offsetByCharacters: end)
                result[lower..<upper].foregroundColor = tagColor
                // Attribute values inside the tag.
                var quote = index
                while quote < end {
                    if characters[quote] == "\"" {
                        var close = quote + 1
                        while close < end, characters[close] != "\"" { close += 1 }
                        let qLower = result.index(result.startIndex, offsetByCharacters: quote)
                        let qUpper = result.index(result.startIndex, offsetByCharacters: min(close + 1, end))
                        result[qLower..<qUpper].foregroundColor = stringColor
                        quote = close + 1
                    } else {
                        quote += 1
                    }
                }
                index = end
            } else {
                index += 1
            }
        }
        return result
    }
}

/// Markdown to HTML for the preview (headings, lists, quotes, code, tables, inline styles).
struct MarkdownHTML {
    static func render(_ markdown: String) -> String {
        var html = ""
        var inCode = false
        var inList = false
        var tableRows: [[String]] = []
        func flushTable() {
            guard !tableRows.isEmpty else { return }
            html += "<table>"
            for (index, row) in tableRows.enumerated() where !(index == 1 && row.allSatisfy { $0.allSatisfy { "-: ".contains($0) } }) {
                let tag = index == 0 ? "th" : "td"
                html += "<tr>" + row.map { "<\(tag)>\(inline($0))</\(tag)>" }.joined() + "</tr>"
            }
            html += "</table>"
            tableRows = []
        }
        for raw in markdown.components(separatedBy: "\n") {
            let line = raw
            if line.hasPrefix("```") {
                html += inCode ? "</code></pre>" : "<pre><code>"
                inCode.toggle()
                continue
            }
            if inCode { html += escape(line) + "\n"; continue }
            if line.hasPrefix("|") {
                tableRows.append(line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) })
                continue
            }
            flushTable()
            let isItem = line.hasPrefix("- ") || line.range(of: #"^\d+\. "#, options: .regularExpression) != nil
            if inList, !isItem { html += "</ul>"; inList = false }
            if let level = line.firstIndex(where: { $0 != "#" }).map({ line.distance(from: line.startIndex, to: $0) }), level > 0, level <= 6, line.dropFirst(level).hasPrefix(" ") {
                html += "<h\(level)>\(inline(String(line.dropFirst(level + 1))))</h\(level)>"
            } else if isItem {
                if !inList { html += "<ul>"; inList = true }
                let text = line.hasPrefix("- ") ? String(line.dropFirst(2)) : String(line[line.range(of: ". ")!.upperBound...])
                html += "<li>\(inline(text))</li>"
            } else if line.hasPrefix("> ") {
                html += "<blockquote>\(inline(String(line.dropFirst(2))))</blockquote>"
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                html += ""
            } else {
                html += "<p>\(inline(line))</p>"
            }
        }
        flushTable()
        if inList { html += "</ul>" }
        return """
        <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        :root { color-scheme: light dark; }
        body { font: -apple-system-body; margin: 20px; line-height: 1.5; }
        h1 { font-size: 1.6em; } h2 { font-size: 1.3em; margin-top: 1.4em; }
        code { font-family: ui-monospace, monospace; font-size: 0.9em; background: rgba(127,127,127,.16); padding: 1px 5px; border-radius: 6px; }
        pre { background: rgba(127,127,127,.12); padding: 12px; border-radius: 12px; overflow-x: auto; }
        pre code { background: none; padding: 0; }
        blockquote { margin: 0; padding-left: 12px; border-left: 3px solid rgba(127,127,127,.4); color: gray; }
        table { border-collapse: collapse; } th, td { border-bottom: 0.5px solid rgba(127,127,127,.4); padding: 6px 10px; text-align: left; }
        </style></head><body>\(html)</body></html>
        """
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func inline(_ text: String) -> String {
        var out = escape(text)
        let rules: [(String, String)] = [
            (#"`([^`]+)`"#, "<code>$1</code>"),
            (#"\*\*([^*]+)\*\*"#, "<b>$1</b>"),
            (#"\[([^\]]+)\]\(([^)]+)\)"#, "<a href=\"$2\">$1</a>"),
        ]
        for (pattern, template) in rules {
            out = out.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return out
    }
}
#endif
