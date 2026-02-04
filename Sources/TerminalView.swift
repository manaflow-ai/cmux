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

// Custom wrapper to handle first responder and layout
class FocusableTerminalView: NSView {
    var terminalView: LocalProcessTerminalView?
    private var scroller: NSScroller?
    private var fadeTimer: Timer?
    private var scrollMonitor: Any?
    private var lastScrollerValue: Double = 0

    override var acceptsFirstResponder: Bool { true }

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
        if let tv = terminalView, bounds.size.width > 0, bounds.size.height > 0 {
            tv.setFrameSize(bounds.size)
            setupScrollerTracking(in: tv)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, let tv = terminalView, bounds.size.width > 0 {
            tv.setFrameSize(bounds.size)
            setupScrollerTracking(in: tv)
            setupScrollMonitor()
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil, let monitor = scrollMonitor {
            NSEvent.removeMonitor(monitor)
            scrollMonitor = nil
        }
    }

    private func setupScrollerTracking(in view: NSView) {
        if scroller == nil {
            for subview in view.subviews {
                if let s = subview as? NSScroller {
                    scroller = s
                    s.alphaValue = 0  // Start hidden
                    lastScrollerValue = s.doubleValue
                    break
                }
            }
        }
    }

    private func setupScrollMonitor() {
        guard scrollMonitor == nil else { return }

        // Monitor scroll wheel events
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            if let self = self,
               let window = self.window,
               event.window == window {
                self.showScrollerTemporarily()
            }
            return event
        }
    }

    func showScrollerTemporarily() {
        guard let scroller = scroller else { return }

        // Show scroller
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            scroller.animator().alphaValue = 1
        }

        // Cancel existing timer
        fadeTimer?.invalidate()

        // Fade out after 1.5 seconds of no scrolling
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                self?.scroller?.animator().alphaValue = 0
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

        let terminalView = LocalProcessTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))

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

        containerView.addSubview(terminalView)
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
                    self.tab.applyProcessTitle(title)
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
