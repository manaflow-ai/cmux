import SwiftUI
import SwiftTerm
import AppKit

// Helper to create SwiftTerm Color from hex
extension SwiftTerm.Color {
    convenience init(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        var rgb: UInt64 = 0
        Scanner(string: hexSanitized).scanHexInt64(&rgb)

        let r = UInt16((rgb & 0xFF0000) >> 16)
        let g = UInt16((rgb & 0x00FF00) >> 8)
        let b = UInt16(rgb & 0x0000FF)

        // Convert 8-bit to 16-bit
        self.init(red: r * 257, green: g * 257, blue: b * 257)
    }
}

struct TerminalContainerView: View {
    @ObservedObject var tab: Tab
    let config: GhosttyConfig

    init(tab: Tab, config: GhosttyConfig = GhosttyConfig.load()) {
        self.tab = tab
        self.config = config
    }

    var body: some View {
        SwiftTermView(tab: tab, config: config)
            .background(Color(config.backgroundColor))
    }
}

final class ScrollReportingTerminalView: LocalProcessTerminalView {
    var onScroll: (() -> Void)?

    override func scrolled(source: TerminalView, position: Double) {
        super.scrolled(source: source, position: position)
        onScroll?()
    }

    override func scrollWheel(with event: NSEvent) {
        if let scrollView = enclosingScrollView {
            scrollView.scrollWheel(with: event)
            return
        }
        super.scrollWheel(with: event)
    }
}

// Custom wrapper to handle first responder and native scrollbars
class FocusableTerminalView: NSView {
    private let scrollView = NSScrollView()
    private let documentView = NSView()
    private let debugScrollerOverlay = NSView()
    var terminalView: ScrollReportingTerminalView? {
        didSet {
            configureTerminalView()
        }
    }
    private var observers: [NSObjectProtocol] = []
    private var isLiveScrolling = false
    private var isProgrammaticScroll = false
    private var lastSentPosition: Double?

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupScrollView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupScrollView()
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    override func becomeFirstResponder() -> Bool {
        if let tv = terminalView {
            DispatchQueue.main.async {
                self.window?.makeFirstResponder(tv)
            }
        }
        return true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(terminalView)
        super.mouseDown(with: event)
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        let scrollerWidth = NSScroller.scrollerWidth(for: .regular, scrollerStyle: scrollView.scrollerStyle)
        debugScrollerOverlay.frame = NSRect(x: bounds.maxX - scrollerWidth, y: 0, width: scrollerWidth, height: bounds.height)
        if let tv = terminalView, bounds.size.width > 0, bounds.size.height > 0 {
            tv.setFrameSize(scrollView.contentSize)
            documentView.frame.size.width = scrollView.bounds.width
            synchronizeScrollView()
            synchronizeTerminalView()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, let tv = terminalView, bounds.size.width > 0 {
            tv.setFrameSize(scrollView.contentSize)
            documentView.frame.size.width = scrollView.bounds.width
            synchronizeScrollView()
            synchronizeTerminalView()
        }
    }

    private func setupScrollView() {
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = false
        scrollView.usesPredominantAxisScrolling = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.contentView.clipsToBounds = false
        scrollView.documentView = documentView
        addSubview(scrollView)

        debugScrollerOverlay.wantsLayer = true
        debugScrollerOverlay.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.25).cgColor
        addSubview(debugScrollerOverlay)

        scrollView.contentView.postsBoundsChangedNotifications = true
        observers.append(NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            self?.handleScrollChange()
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSScrollView.willStartLiveScrollNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            self?.isLiveScrolling = true
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSScrollView.didEndLiveScrollNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            self?.isLiveScrolling = false
        })
    }

    private func configureTerminalView() {
        guard let tv = terminalView else { return }
        tv.onScroll = { [weak self] in
            self?.synchronizeScrollView()
        }
        documentView.addSubview(tv)
        hideInternalScroller(in: tv)
        synchronizeScrollView()
        synchronizeTerminalView()
    }

    private func documentHeight() -> CGFloat {
        let contentHeight = scrollView.contentSize.height
        guard let tv = terminalView, tv.canScroll else { return contentHeight }
        let thumb = max(tv.scrollThumbsize, 0.01)
        return max(contentHeight / thumb, contentHeight)
    }

    private func synchronizeScrollView() {
        documentView.frame.size.height = documentHeight()
        guard let tv = terminalView else { return }

        if !isLiveScrolling {
            let contentHeight = scrollView.contentSize.height
            let maxOffset = max(documentView.frame.height - contentHeight, 0)
            let offsetY = (1 - tv.scrollPosition) * maxOffset
            isProgrammaticScroll = true
            scrollView.contentView.scroll(to: CGPoint(x: 0, y: offsetY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            isProgrammaticScroll = false
        } else {
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    private func synchronizeTerminalView() {
        guard let tv = terminalView else { return }
        let visibleRect = scrollView.contentView.documentVisibleRect
        tv.frame.origin = visibleRect.origin
        tv.frame.size = scrollView.contentSize
    }

    private func handleScrollChange() {
        synchronizeTerminalView()
        guard !isProgrammaticScroll, let tv = terminalView else { return }
        let contentHeight = scrollView.contentSize.height
        let maxOffset = max(documentView.frame.height - contentHeight, 0)
        guard maxOffset > 0 else { return }
        let offsetY = scrollView.contentView.documentVisibleRect.origin.y
        let position = 1 - Double(offsetY / maxOffset)
        if let last = lastSentPosition, abs(last - position) < 0.0001 {
            return
        }
        lastSentPosition = position
        tv.scroll(toPosition: position)
    }

    private func hideInternalScroller(in view: NSView) {
        for subview in view.subviews {
            if let scroller = subview as? NSScroller {
                scroller.isHidden = true
                scroller.alphaValue = 0
            } else if !subview.subviews.isEmpty {
                hideInternalScroller(in: subview)
            }
        }
    }
}

struct SwiftTermView: NSViewRepresentable {
    @ObservedObject var tab: Tab
    let config: GhosttyConfig

    func makeNSView(context: Context) -> FocusableTerminalView {
        let containerView = FocusableTerminalView()
        containerView.wantsLayer = true

        let terminalView = ScrollReportingTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))

        // Use autoresizingMask instead of Auto Layout for SwiftTerm compatibility
        terminalView.autoresizingMask = [.width, .height]

        // Apply Ghostty config colors
        terminalView.nativeForegroundColor = config.foregroundColor
        terminalView.nativeBackgroundColor = config.backgroundColor

        // Set cursor color to match Ghostty
        terminalView.caretColor = config.cursorColor
        terminalView.caretTextColor = config.cursorTextColor

        // Set selection colors
        terminalView.selectedTextBackgroundColor = config.selectionBackground

        // Apply ANSI palette colors
        applyPalette(to: terminalView, config: config)

        // Configure font from config
        if let font = NSFont(name: config.fontFamily, size: config.fontSize) {
            terminalView.font = font
        } else {
            terminalView.font = NSFont.monospacedSystemFont(ofSize: config.fontSize, weight: .regular)
        }

        // Set terminal delegate (only processDelegate, not terminalDelegate which breaks input)
        terminalView.processDelegate = context.coordinator
        context.coordinator.terminalView = terminalView
        context.coordinator.containerView = containerView

        containerView.terminalView = terminalView

        // Get shell path
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"

        // Determine working directory
        let workingDir = config.workingDirectory ?? FileManager.default.homeDirectoryForCurrentUser.path

        // Build environment with working directory
        var env = ProcessInfo.processInfo.environment
        env["PWD"] = workingDir

        // Start the shell process
        terminalView.startProcess(
            executable: shell,
            args: [],
            environment: env.map { "\($0.key)=\($0.value)" },
            execName: "-" + (shell as NSString).lastPathComponent
        )

        // Change to working directory
        terminalView.feed(text: "cd \"\(workingDir)\" && clear\n")


        // Make first responder after a delay to ensure window is ready
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            containerView.window?.makeFirstResponder(terminalView)
        }

        return containerView
    }

    func updateNSView(_ nsView: FocusableTerminalView, context: Context) {
        // When this view becomes visible (tab switch), make it first responder
        DispatchQueue.main.async {
            if let terminalView = nsView.terminalView {
                nsView.window?.makeFirstResponder(terminalView)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(tab: tab)
    }

    private func applyPalette(to terminalView: LocalProcessTerminalView, config: GhosttyConfig) {
        // SwiftTerm uses installColors to set the ANSI color palette
        // Build the color array (16 ANSI colors)

        // Default Monokai Classic palette hex values
        let defaultPaletteHex: [String] = [
            "#272822", // 0 - black
            "#f92672", // 1 - red
            "#a6e22e", // 2 - green
            "#e6db74", // 3 - yellow
            "#fd971f", // 4 - blue (orange in Monokai)
            "#ae81ff", // 5 - magenta
            "#66d9ef", // 6 - cyan
            "#fdfff1", // 7 - white
            "#6e7066", // 8 - bright black
            "#f92672", // 9 - bright red
            "#a6e22e", // 10 - bright green
            "#e6db74", // 11 - bright yellow
            "#fd971f", // 12 - bright blue
            "#ae81ff", // 13 - bright magenta
            "#66d9ef", // 14 - bright cyan
            "#fdfff1", // 15 - bright white
        ]

        var colors: [SwiftTerm.Color] = []
        for i in 0..<16 {
            colors.append(SwiftTerm.Color(hex: defaultPaletteHex[i]))
        }

        // Install the ANSI colors
        terminalView.installColors(colors)
    }

    class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        var tab: Tab
        weak var terminalView: LocalProcessTerminalView?
        weak var containerView: FocusableTerminalView?

        init(tab: Tab) {
            self.tab = tab
        }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
            // Handle size change
        }

        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
            DispatchQueue.main.async {
                if !title.isEmpty {
                    self.tab.title = title
                }
            }
        }

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
            if let dir = directory {
                DispatchQueue.main.async {
                    self.tab.currentDirectory = dir
                }
            }
        }

        func processTerminated(source: TerminalView, exitCode: Int32?) {
            // Could close tab or show message
        }
    }
}
