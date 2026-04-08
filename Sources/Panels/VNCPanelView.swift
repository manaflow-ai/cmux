import AppKit
import SwiftUI
import RoyalVNCKit

/// SwiftUI view that renders a VNCPanel's remote desktop via RoyalVNCKit.
struct VNCPanelView: View {
    @ObservedObject var panel: VNCPanel
    let isFocused: Bool
    let isVisibleInUI: Bool
    let portalPriority: Int
    let onRequestPanelFocus: () -> Void

    @State private var focusFlashOpacity: Double = 0.0
    @State private var focusFlashAnimationGeneration: Int = 0

    var body: some View {
        Group {
            if panel.isConnected, panel.framebufferView != nil {
                connectedView
            } else {
                connectionView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: NSColor(srgbRed: 10.0/255.0, green: 10.0/255.0, blue: 10.0/255.0, alpha: 1.0)))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(cmuxAccentColor().opacity(focusFlashOpacity), lineWidth: 3)
                .shadow(color: cmuxAccentColor().opacity(focusFlashOpacity * 0.35), radius: 10)
                .padding(2)
                .allowsHitTesting(false)
        }
        .onChange(of: panel.focusFlashToken) { _ in
            triggerFocusFlashAnimation()
        }
    }

    // MARK: - Connected View (framebuffer + toolbar overlay)

    private var connectedView: some View {
        ZStack(alignment: .topTrailing) {
            VNCFramebufferRepresentable(panel: panel)

            // Toolbar overlay — action buttons
            HStack(spacing: 6) {
                // Scaling mode toggle
                vncToolbarButton(
                    icon: panel.scalingMode == .fitToWindow
                        ? "arrow.up.left.and.arrow.down.right"
                        : "1.square",
                    label: panel.scalingMode == .fitToWindow ? "Fit" : "1:1"
                ) {
                    panel.scalingMode = panel.scalingMode == .fitToWindow
                        ? .actualSize : .fitToWindow
                }

                // Ctrl+Alt+Del button (for Windows VMs)
                vncToolbarButton(icon: "keyboard", label: "Ctrl+Alt+Del") {
                    panel.sendCtrlAltDel()
                }

                vncToolbarButton(icon: "xmark.circle.fill", label: "Disconnect") {
                    panel.disconnect()
                }
            }
            .padding(8)
            .opacity(isHoveringToolbar ? 1 : 0.15)
            .animation(.easeInOut(duration: 0.2), value: isHoveringToolbar)
            .onHover { hovering in
                isHoveringToolbar = hovering
            }
        }
    }

    @State private var isHoveringToolbar: Bool = false

    private func vncToolbarButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                Text(label)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(white: 0.1).opacity(0.85))
            .cornerRadius(4)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color(white: 0.25), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .foregroundColor(Color(white: 0.7))
    }

    // MARK: - Connection View

    private var connectionView: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "display")
                .font(.system(size: 48, weight: .thin))
                .foregroundColor(Color(white: 0.4))

            Text("VNC Remote Desktop")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Color(white: 0.7))

            // Status
            Text(panel.connectionStatus)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundColor(statusColor)

            // Error message
            if let error = panel.errorMessage, !error.isEmpty {
                Text(error)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Color(white: 0.6))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                    .padding(.vertical, 4)
                    .background(Color(white: 0.08))
                    .cornerRadius(4)
            }

            // Recent connections
            if !panel.recentConnections.isEmpty {
                VStack(spacing: 4) {
                    HStack(spacing: 8) {
                        Text("Recent")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(Color(white: 0.45))
                            .frame(width: 32, alignment: .trailing)
                        Menu {
                            ForEach(panel.recentConnections) { recent in
                                Button(recent.displayLabel) {
                                    panel.applyRecentConnection(recent)
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .font(.system(size: 10))
                                Text(panel.recentConnections.first?.displayLabel ?? "")
                                    .font(.system(size: 11, design: .monospaced))
                                    .lineLimit(1)
                                Spacer()
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 8))
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Color(white: 0.08))
                            .cornerRadius(4)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(Color(white: 0.18), lineWidth: 1)
                            )
                        }
                        .menuStyle(.borderlessButton)
                        .foregroundColor(Color(white: 0.6))
                    }
                }
                .frame(width: 320)
            }

            // Connection form
            VStack(spacing: 10) {
                // Host:Port row
                HStack(spacing: 8) {
                    VNCTextField(label: "Host", text: $panel.hostname, placeholder: "localhost")
                    VNCTextField(label: "Port", text: portBinding, placeholder: "5900")
                        .frame(width: 80)
                }

                // Username
                VNCTextField(label: "User", text: $panel.username, placeholder: NSUserName())

                // Password
                HStack(spacing: 8) {
                    Text("Pass")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(Color(white: 0.45))
                        .frame(width: 32, alignment: .trailing)
                    SecureField("", text: $panel.password)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color(white: 0.08))
                        .cornerRadius(4)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color(white: 0.18), lineWidth: 1)
                        )
                }

                // Color depth
                HStack(spacing: 8) {
                    Text("Color")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(Color(white: 0.45))
                        .frame(width: 32, alignment: .trailing)
                    Picker("", selection: $panel.selectedColorDepth) {
                        Text("8-bit").tag(VNCConnection.Settings.ColorDepth.depth8Bit)
                        Text("16-bit").tag(VNCConnection.Settings.ColorDepth.depth16Bit)
                        Text("24-bit").tag(VNCConnection.Settings.ColorDepth.depth24Bit)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }
            .frame(width: 320)

            // Buttons
            HStack(spacing: 10) {
                if panel.isConnecting {
                    // Connecting state: spinner + cancel
                    Button(action: { panel.disconnect() }) {
                        HStack(spacing: 6) {
                            ProgressView()
                                .scaleEffect(0.5)
                                .frame(width: 10, height: 10)
                            Text("Connecting...")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(Color(white: 0.1))
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color(white: 0.25), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(Color(white: 0.5))
                } else if panel.hasConnectedBefore {
                    // After disconnection: reconnect + connect
                    Button(action: { panel.reconnect() }) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 10))
                            Text("Reconnect")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(Color(white: 0.15))
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color(white: 0.25), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(Color(white: 0.8))
                } else {
                    // Initial state: connect
                    Button(action: { panel.connect() }) {
                        HStack(spacing: 6) {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 10))
                            Text("Connect")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(Color(white: 0.15))
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color(white: 0.25), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(Color(white: 0.8))
                }
            }
            .padding(.top, 4)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var portBinding: Binding<String> {
        Binding<String>(
            get: { String(panel.port) },
            set: { panel.port = UInt16($0) ?? 5900 }
        )
    }

    private var statusColor: Color {
        if panel.errorMessage != nil && !panel.errorMessage!.isEmpty {
            return Color(red: 0.8, green: 0.3, blue: 0.3)
        }
        if panel.isConnecting {
            return Color(white: 0.5)
        }
        if panel.isConnected {
            return Color(white: 0.6)
        }
        return Color(white: 0.4)
    }

    // MARK: - Focus flash

    private func triggerFocusFlashAnimation() {
        let generation = focusFlashAnimationGeneration + 1
        focusFlashAnimationGeneration = generation

        withAnimation(.easeIn(duration: 0.15)) {
            focusFlashOpacity = 0.6
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard focusFlashAnimationGeneration == generation else { return }
            withAnimation(.easeOut(duration: 0.4)) {
                focusFlashOpacity = 0.0
            }
        }
    }
}

// MARK: - Reusable text field

private struct VNCTextField: View {
    let label: String
    @Binding var text: String
    let placeholder: String

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(Color(white: 0.45))
                .frame(width: 32, alignment: .trailing)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color(white: 0.08))
                .cornerRadius(4)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color(white: 0.18), lineWidth: 1)
                )
        }
    }
}

// MARK: - NSViewRepresentable wrapping VNCCAFramebufferView

struct VNCFramebufferRepresentable: NSViewRepresentable {
    let panel: VNCPanel

    func makeNSView(context: Context) -> VNCFramebufferContainer {
        VNCFramebufferContainer(frame: .zero)
    }

    func updateNSView(_ container: VNCFramebufferContainer, context: Context) {
        guard let fbView = panel.framebufferView else { return }
        container.configure(
            panel: panel,
            fbView: fbView,
            mode: panel.scalingMode,
            framebufferSize: fbView.framebufferSize
        )
    }
}

// MARK: - Container: manual CGImage rendering + VNCCAFramebufferView for input

final class VNCFramebufferContainer: NSView {
    private var scrollView: NSScrollView?
    private weak var currentFBView: VNCCAFramebufferView?
    private weak var currentPanel: VNCPanel?
    private var currentMode: VNCScalingMode = .fitToWindow
    private var activeConstraints: [NSLayoutConstraint] = []

    /// Manual rendering layer — we draw framebuffer.cgImage here ourselves
    /// because VNCCAFramebufferView's internal Metal/DisplayLink pipeline
    /// fails when the view is created outside a window (NSViewRepresentable).
    private var renderLayer: CALayer?
    private var renderTimer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    deinit {
        renderTimer?.invalidate()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            renderTimer?.invalidate()
            renderTimer = nil
        } else if currentFBView != nil, renderTimer == nil {
            startRenderTimer()
        }
    }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        if let fbView = currentFBView {
            window?.makeFirstResponder(fbView)
            fbView.mouseDown(with: event)
        } else {
            super.mouseDown(with: event)
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    func configure(panel: VNCPanel, fbView: VNCCAFramebufferView, mode: VNCScalingMode, framebufferSize: CGSize) {
        let needsRebuild = currentFBView !== fbView || currentMode != mode

        if !needsRebuild {
            if mode == .actualSize {
                updateSizeConstraints(framebufferSize)
            }
            return
        }

        // Tear down old layout
        NSLayoutConstraint.deactivate(activeConstraints)
        activeConstraints = []
        currentFBView?.removeFromSuperview()
        scrollView?.removeFromSuperview()
        scrollView = nil
        renderLayer?.removeFromSuperlayer()
        renderTimer?.invalidate()

        currentFBView = fbView
        currentPanel = panel
        currentMode = mode

        // Hide VNCCAFramebufferView's own rendering (Metal/CALayer) — we render manually.
        // Make it transparent so our renderLayer shows through, but keep it in the
        // view hierarchy for mouse/keyboard input handling.
        fbView.translatesAutoresizingMaskIntoConstraints = false
        fbView.alphaValue = 0

        // Create our manual render layer
        let rl = CALayer()
        rl.contentsGravity = .resizeAspect
        rl.contentsScale = 1
        rl.backgroundColor = CGColor.clear
        rl.isOpaque = true
        rl.minificationFilter = .trilinear
        rl.magnificationFilter = .trilinear

        switch mode {
        case .fitToWindow:
            // Render layer fills the container
            layer?.addSublayer(rl)
            self.renderLayer = rl

            // Input view on top (invisible but captures events)
            addSubview(fbView)
            activeConstraints = [
                fbView.leadingAnchor.constraint(equalTo: leadingAnchor),
                fbView.trailingAnchor.constraint(equalTo: trailingAnchor),
                fbView.topAnchor.constraint(equalTo: topAnchor),
                fbView.bottomAnchor.constraint(equalTo: bottomAnchor),
            ]

        case .actualSize:
            let sv = NSScrollView()
            sv.translatesAutoresizingMaskIntoConstraints = false
            sv.drawsBackground = false
            sv.backgroundColor = .clear
            sv.hasVerticalScroller = true
            sv.hasHorizontalScroller = true
            sv.autohidesScrollers = true
            sv.borderType = .noBorder
            sv.allowsMagnification = true
            sv.minMagnification = 0.25
            sv.maxMagnification = 4.0
            sv.magnification = 1.0

            sv.documentView = fbView
            addSubview(sv)

            // For actual size, render layer goes inside scroll view's content
            fbView.wantsLayer = true
            fbView.layer?.addSublayer(rl)
            self.renderLayer = rl

            let w = max(framebufferSize.width, 1)
            let h = max(framebufferSize.height, 1)
            activeConstraints = [
                sv.leadingAnchor.constraint(equalTo: leadingAnchor),
                sv.trailingAnchor.constraint(equalTo: trailingAnchor),
                sv.topAnchor.constraint(equalTo: topAnchor),
                sv.bottomAnchor.constraint(equalTo: bottomAnchor),
                fbView.widthAnchor.constraint(equalToConstant: w),
                fbView.heightAnchor.constraint(equalToConstant: h),
            ]

            scrollView = sv
        }

        NSLayoutConstraint.activate(activeConstraints)

        // Start manual render timer — update the layer with framebuffer.cgImage
        startRenderTimer()

        // Auto-focus for input
        DispatchQueue.main.async {
            fbView.window?.makeFirstResponder(fbView)
        }
    }

    override func layout() {
        super.layout()
        // Keep render layer sized to match container bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if currentMode == .fitToWindow {
            renderLayer?.frame = bounds
        } else if let fbView = currentFBView {
            renderLayer?.frame = fbView.bounds
        }
        CATransaction.commit()
    }

    private func startRenderTimer() {
        renderTimer?.invalidate()
        // ~30 FPS manual rendering
        renderTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.renderFrame()
        }
    }

    private func renderFrame() {
        guard let panel = currentPanel,
              let framebuffer = panel.framebuffer,
              let renderLayer else { return }

        // Get cgImage from the framebuffer (CIImage → CGImage conversion)
        guard let cgImage = framebuffer.cgImage else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        renderLayer.contents = cgImage
        CATransaction.commit()
    }

    private func updateSizeConstraints(_ size: CGSize) {
        let w = max(size.width, 1)
        let h = max(size.height, 1)
        for constraint in activeConstraints where constraint.firstItem is VNCCAFramebufferView {
            if constraint.firstAttribute == .width {
                constraint.constant = w
            } else if constraint.firstAttribute == .height {
                constraint.constant = h
            }
        }
        // Also update render layer size for actual-size mode
        if currentMode == .actualSize {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            renderLayer?.frame = CGRect(origin: .zero, size: CGSize(width: w, height: h))
            CATransaction.commit()
        }
    }
}
