#if DEBUG
import AppKit
import SwiftUI

final class FeedTextEditorDebugWindowController: NSWindowController, NSWindowDelegate {
    static let shared = FeedTextEditorDebugWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(
            localized: "feed.textEditorDebug.windowTitle",
            defaultValue: "Feed Text Editor Lab"
        )
        window.center()
        window.contentView = NSHostingView(rootView: FeedTextEditorDebugView())
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}

private enum FeedTextEditorDebugVariant: String, CaseIterable, Identifiable {
    case swiftUITextField
    case swiftUIMirror
    case appKitDirectSizeThatFits
    case appKitDirectIntrinsic
    case appKitScrollSizeThatFits
    case appKitScrollMeasured

    var id: String { rawValue }

    var title: String {
        switch self {
        case .swiftUITextField:
            return String(localized: "feed.textEditorDebug.variant.swiftUITextField", defaultValue: "SwiftUI TextField")
        case .swiftUIMirror:
            return String(localized: "feed.textEditorDebug.variant.swiftUIMirror", defaultValue: "SwiftUI Mirror TextEditor")
        case .appKitDirectSizeThatFits:
            return String(localized: "feed.textEditorDebug.variant.appKitDirectSize", defaultValue: "AppKit Direct, sizeThatFits")
        case .appKitDirectIntrinsic:
            return String(localized: "feed.textEditorDebug.variant.appKitDirectIntrinsic", defaultValue: "AppKit Direct, intrinsic")
        case .appKitScrollSizeThatFits:
            return String(localized: "feed.textEditorDebug.variant.appKitScrollSize", defaultValue: "AppKit ScrollView, sizeThatFits")
        case .appKitScrollMeasured:
            return String(localized: "feed.textEditorDebug.variant.appKitScrollMeasured", defaultValue: "AppKit ScrollView, measured")
        }
    }
}

private struct FeedTextEditorDebugView: View {
    private let sampleText = "hello from feed"

    @State private var swiftUITextFieldText = "hello from feed"
    @State private var swiftUIMirrorText = "hello from feed"
    @State private var appKitDirectSizeText = "hello from feed"
    @State private var appKitDirectIntrinsicText = "hello from feed"
    @State private var appKitScrollSizeText = "hello from feed"
    @State private var appKitScrollMeasuredText = "hello from feed"
    @State private var mirrorHeight: CGFloat = 34
    @State private var scrollMeasuredHeight: CGFloat = 34

    private var placeholder: String {
        String(localized: "feed.textEditorDebug.placeholder", defaultValue: "Type several lines here...")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                Text(String(localized: "feed.textEditorDebug.section.swiftui", defaultValue: "SwiftUI"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                    debugCard(.swiftUITextField, text: swiftUITextFieldText) {
                        swiftUITextField
                    }
                    debugCard(.swiftUIMirror, text: swiftUIMirrorText) {
                        swiftUIMirrorTextEditor
                    }
                }

                Text(String(localized: "feed.textEditorDebug.section.appkit", defaultValue: "AppKit"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)

                LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                    appKitCard(.appKitDirectSizeThatFits, text: $appKitDirectSizeText, measuredHeight: .constant(34))
                    appKitCard(.appKitDirectIntrinsic, text: $appKitDirectIntrinsicText, measuredHeight: .constant(34))
                    appKitCard(.appKitScrollSizeThatFits, text: $appKitScrollSizeText, measuredHeight: .constant(34))
                    appKitCard(.appKitScrollMeasured, text: $appKitScrollMeasuredText, measuredHeight: $scrollMeasuredHeight)
                }
            }
            .padding(20)
        }
        .frame(minWidth: 760, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var columns: [GridItem] {
        [
            GridItem(.adaptive(minimum: 390), spacing: 14, alignment: .top),
        ]
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "feed.textEditorDebug.title", defaultValue: "Feed Text Editors"))
                    .font(.system(size: 18, weight: .semibold))
                Text(String(
                    localized: "feed.textEditorDebug.subtitle",
                    defaultValue: "Compare autosizing editors with identical input."
                ))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button(String(localized: "feed.textEditorDebug.reset", defaultValue: "Reset")) {
                reset()
            }
        }
    }

    private var swiftUITextField: some View {
        TextField(placeholder, text: $swiftUITextFieldText, axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(1...10)
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(editorBackground)
    }

    private var swiftUIMirrorTextEditor: some View {
        ZStack(alignment: .topLeading) {
            Text(swiftUIMirrorText.isEmpty ? " " : swiftUIMirrorText + " ")
                .font(.system(size: 13, weight: .semibold))
                .lineSpacing(0)
                .padding(.horizontal, 9)
                .padding(.top, 9)
                .padding(.bottom, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(0)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: FeedTextEditorDebugHeightKey.self, value: proxy.size.height)
                    }
                )
            TextEditor(text: $swiftUIMirrorText)
                .font(.system(size: 13, weight: .semibold))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 4)
                .padding(.top, 5)
                .padding(.bottom, 3)
                .frame(height: max(34, mirrorHeight))
        }
        .background(editorBackground)
        .onPreferenceChange(FeedTextEditorDebugHeightKey.self) { height in
            mirrorHeight = max(34, ceil(height))
        }
    }

    @ViewBuilder
    private func appKitCard(
        _ variant: FeedTextEditorDebugVariant,
        text: Binding<String>,
        measuredHeight: Binding<CGFloat>
    ) -> some View {
        let mode = FeedTextEditorDebugAppKitMode(variant: variant)
        debugCard(variant, text: text.wrappedValue) {
            let editor = FeedTextEditorDebugAppKitEditor(
                text: text,
                measuredHeight: measuredHeight,
                mode: mode,
                placeholder: placeholder
            )
            .frame(maxWidth: .infinity, minHeight: 34)

            if mode.reportsHeight {
                editor.frame(height: max(34, measuredHeight.wrappedValue))
            } else {
                editor
            }
        }
    }

    private func debugCard<Content: View>(
        _ variant: FeedTextEditorDebugVariant,
        text: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(variant.title)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(metrics(for: text))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            content()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.055))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.10), lineWidth: 1)
        )
    }

    private var editorBackground: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color(nsColor: .textBackgroundColor).opacity(0.90))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.primary.opacity(0.16), lineWidth: 1)
            )
    }

    private func metrics(for text: String) -> String {
        let lineCount = Int64(text.filter { $0 == "\n" }.count + 1)
        let charCount = Int64((text as NSString).length)
        let format = String(localized: "feed.textEditorDebug.metrics", defaultValue: "%lld lines · %lld chars")
        return String(format: format, lineCount, charCount)
    }

    private func reset() {
        swiftUITextFieldText = sampleText
        swiftUIMirrorText = sampleText
        appKitDirectSizeText = sampleText
        appKitDirectIntrinsicText = sampleText
        appKitScrollSizeText = sampleText
        appKitScrollMeasuredText = sampleText
        mirrorHeight = 34
        scrollMeasuredHeight = 34
    }
}

private struct FeedTextEditorDebugHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 34

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private enum FeedTextEditorDebugAppKitMode {
    case directSizeThatFits
    case directIntrinsic
    case scrollSizeThatFits
    case scrollMeasured

    init(variant: FeedTextEditorDebugVariant) {
        switch variant {
        case .appKitDirectIntrinsic:
            self = .directIntrinsic
        case .appKitScrollSizeThatFits:
            self = .scrollSizeThatFits
        case .appKitScrollMeasured:
            self = .scrollMeasured
        default:
            self = .directSizeThatFits
        }
    }

    var wrapsInScrollView: Bool {
        switch self {
        case .directSizeThatFits, .directIntrinsic:
            return false
        case .scrollSizeThatFits, .scrollMeasured:
            return true
        }
    }

    var usesSizeThatFits: Bool {
        switch self {
        case .directSizeThatFits, .scrollSizeThatFits:
            return true
        case .directIntrinsic, .scrollMeasured:
            return false
        }
    }

    var reportsHeight: Bool {
        if case .scrollMeasured = self { return true }
        return false
    }

    var usesIntrinsicHeight: Bool {
        if case .directIntrinsic = self { return true }
        return false
    }

    var textInset: NSSize {
        switch self {
        case .directSizeThatFits, .directIntrinsic:
            return NSSize(width: 0, height: 1)
        case .scrollSizeThatFits, .scrollMeasured:
            return NSSize(width: 5, height: 4)
        }
    }
}

private struct FeedTextEditorDebugAppKitEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var measuredHeight: CGFloat

    let mode: FeedTextEditorDebugAppKitMode
    let placeholder: String

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: FeedTextEditorDebugAppKitEditor
        weak var host: FeedTextEditorDebugAppKitHost?
        var isProgrammaticMutation = false

        init(parent: FeedTextEditorDebugAppKitEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard !isProgrammaticMutation,
                  let textView = notification.object as? NSTextView else {
                return
            }
            parent.text = textView.string
            host?.refreshMetrics()
        }

        func updateMeasuredHeight(_ height: CGFloat) {
            guard parent.mode.reportsHeight, abs(parent.measuredHeight - height) > 0.5 else { return }
            DispatchQueue.main.async {
                self.parent.measuredHeight = height
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> FeedTextEditorDebugAppKitHost {
        let host = FeedTextEditorDebugAppKitHost(frame: .zero)
        host.textView.delegate = context.coordinator
        host.onMeasuredHeightChange = { [weak coordinator = context.coordinator] height in
            coordinator?.updateMeasuredHeight(height)
        }
        context.coordinator.host = host
        host.textView.string = text
        configure(host)
        return host
    }

    func updateNSView(_ nsView: FeedTextEditorDebugAppKitHost, context: Context) {
        context.coordinator.parent = self
        context.coordinator.host = nsView
        nsView.textView.delegate = context.coordinator
        nsView.onMeasuredHeightChange = { [weak coordinator = context.coordinator] height in
            coordinator?.updateMeasuredHeight(height)
        }
        configure(nsView)
        if nsView.textView.string != text, !nsView.textView.hasMarkedText() {
            context.coordinator.isProgrammaticMutation = true
            nsView.textView.string = text
            context.coordinator.isProgrammaticMutation = false
            nsView.refreshMetrics()
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: FeedTextEditorDebugAppKitHost,
        context: Context
    ) -> CGSize? {
        guard mode.usesSizeThatFits, let width = proposal.width else { return nil }
        return CGSize(width: width, height: nsView.fittingHeight(for: width))
    }

    static func dismantleNSView(_ nsView: FeedTextEditorDebugAppKitHost, coordinator: Coordinator) {
        nsView.textView.delegate = nil
        nsView.onMeasuredHeightChange = nil
    }

    private func configure(_ host: FeedTextEditorDebugAppKitHost) {
        host.apply(
            mode: mode,
            font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            placeholder: placeholder
        )
    }
}

private final class FeedTextEditorDebugAppKitHost: NSView {
    let textView = NSTextView(frame: .zero)
    private let scrollView = NSScrollView(frame: .zero)
    private let placeholderField = NSTextField(labelWithString: "")
    private var mode = FeedTextEditorDebugAppKitMode.directSizeThatFits
    private var currentFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    private var lastMeasuredHeight: CGFloat = 0

    var onMeasuredHeightChange: ((CGFloat) -> Void)?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )

        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.automaticallyAdjustsContentInsets = false

        placeholderField.textColor = .placeholderTextColor
        placeholderField.lineBreakMode = .byTruncatingTail
        addSubview(textView)
        addSubview(placeholderField)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        if mode.usesIntrinsicHeight {
            return NSSize(width: NSView.noIntrinsicMetric, height: fittingHeight())
        }
        return NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func mouseDown(with event: NSEvent) {
        _ = window?.makeFirstResponder(textView)
        super.mouseDown(with: event)
    }

    override func layout() {
        super.layout()
        layoutEditor()
        reportMeasuredHeightIfNeeded()
    }

    func apply(mode: FeedTextEditorDebugAppKitMode, font: NSFont, placeholder: String) {
        self.mode = mode
        currentFont = font
        textView.font = font
        textView.textContainerInset = mode.textInset
        textView.textColor = .labelColor
        textView.insertionPointColor = .controlAccentColor
        placeholderField.stringValue = placeholder
        placeholderField.font = font
        installEditorContainerIfNeeded()
        refreshMetrics()
    }

    func refreshMetrics() {
        placeholderField.isHidden = !textView.string.isEmpty
        needsLayout = true
        invalidateIntrinsicContentSize()
        layoutSubtreeIfNeeded()
        reportMeasuredHeightIfNeeded()
    }

    func fittingHeight(for width: CGFloat) -> CGFloat {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else {
            return minimumHeight()
        }
        let availableWidth = max(width - mode.textInset.width * 2, 1)
        textContainer.containerSize = NSSize(width: availableWidth, height: CGFloat.greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        let lineHeight = ceil(currentFont.ascender - currentFont.descender + currentFont.leading)
        let contentHeight = max(lineHeight, ceil(usedRect.height))
        return max(minimumHeight(), ceil(contentHeight + mode.textInset.height * 2))
    }

    private func fittingHeight() -> CGFloat {
        fittingHeight(for: max(bounds.width, 1))
    }

    private func minimumHeight() -> CGFloat {
        ceil(currentFont.ascender - currentFont.descender + currentFont.leading) + mode.textInset.height * 2
    }

    private func installEditorContainerIfNeeded() {
        if mode.wrapsInScrollView {
            if scrollView.superview == nil {
                textView.removeFromSuperview()
                scrollView.documentView = textView
                addSubview(scrollView, positioned: .below, relativeTo: placeholderField)
            }
        } else if textView.superview !== self {
            scrollView.documentView = nil
            scrollView.removeFromSuperview()
            addSubview(textView, positioned: .below, relativeTo: placeholderField)
        }
    }

    private func layoutEditor() {
        let availableWidth = max(bounds.width, 1)
        let height = fittingHeight(for: availableWidth)
        if mode.wrapsInScrollView {
            scrollView.frame = bounds
            textView.frame = NSRect(
                x: 0,
                y: 0,
                width: availableWidth,
                height: max(height, bounds.height)
            )
        } else {
            textView.frame = NSRect(x: 0, y: 0, width: availableWidth, height: height)
        }
        placeholderField.frame = NSRect(
            x: mode.textInset.width,
            y: mode.textInset.height,
            width: max(bounds.width - mode.textInset.width * 2, 1),
            height: minimumHeight()
        )
    }

    private func reportMeasuredHeightIfNeeded() {
        guard mode.reportsHeight else { return }
        let height = fittingHeight()
        guard abs(lastMeasuredHeight - height) > 0.5 else { return }
        lastMeasuredHeight = height
        onMeasuredHeightChange?(height)
    }
}
#endif
