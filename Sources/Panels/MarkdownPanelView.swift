import AppKit
import SwiftUI
import MarkdownUI

/// SwiftUI view that renders a MarkdownPanel's content using MarkdownUI.
struct MarkdownPanelView: View {
    @ObservedObject var panel: MarkdownPanel
    let isFocused: Bool
    let isVisibleInUI: Bool
    let portalPriority: Int
    let onRequestPanelFocus: () -> Void

    @State private var focusFlashOpacity: Double = 0.0
    @State private var focusFlashAnimationGeneration: Int = 0
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if panel.isFileUnavailable {
                fileUnavailableView
            } else {
                markdownContentView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(backgroundColor)
        .overlay {
            RoundedRectangle(cornerRadius: FocusFlashPattern.ringCornerRadius)
                .stroke(cmuxAccentColor().opacity(focusFlashOpacity), lineWidth: 3)
                .shadow(color: cmuxAccentColor().opacity(focusFlashOpacity * 0.35), radius: 10)
                .padding(FocusFlashPattern.ringInset)
                .allowsHitTesting(false)
        }
        .overlay {
            if isVisibleInUI {
                // Observe left-clicks without intercepting them so markdown text
                // selection and link activation continue to use the native path.
                MarkdownPointerObserver(onPointerDown: onRequestPanelFocus)
            }
        }
        .onChange(of: panel.focusFlashToken) { _ in
            triggerFocusFlashAnimation()
        }
    }

    // MARK: - Content

    private var markdownContentView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // File path breadcrumb
                filePathHeader
                    .padding(.horizontal, 24)
                    .padding(.top, 16)
                    .padding(.bottom, 8)

                Divider()
                    .padding(.horizontal, 16)

                // Rendered markdown
                Markdown(panel.content)
                    .markdownTheme(cmuxMarkdownTheme)
                    .textSelection(.enabled)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
            }
        }
    }

    private var filePathHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.richtext")
                .foregroundColor(.secondary)
                .font(.system(size: 12))
            Text(panel.filePath)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
    }

    private var fileUnavailableView: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.questionmark")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text(String(localized: "markdown.fileUnavailable.title", defaultValue: "File unavailable"))
                .font(.headline)
                .foregroundColor(.primary)
            Text(panel.filePath)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)
            Text(String(localized: "markdown.fileUnavailable.message", defaultValue: "The file may have been moved or deleted."))
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Theme

    private var backgroundColor: Color {
        colorScheme == .dark
            ? Color(nsColor: NSColor(white: 0.12, alpha: 1.0))
            : Color(nsColor: NSColor(white: 0.98, alpha: 1.0))
    }

    private var cmuxMarkdownTheme: Theme {
        let isDark = colorScheme == .dark

        return Theme()
            // Text
            .text {
                ForegroundColor(isDark ? .white.opacity(0.9) : .primary)
                FontSize(14)
            }
            // Headings
            .heading1 { configuration in
                VStack(alignment: .leading, spacing: 8) {
                    configuration.label
                        .markdownTextStyle {
                            FontWeight(.bold)
                            FontSize(28)
                            ForegroundColor(isDark ? .white : .primary)
                        }
                    Divider()
                }
                .markdownMargin(top: 24, bottom: 16)
            }
            .heading2 { configuration in
                VStack(alignment: .leading, spacing: 6) {
                    configuration.label
                        .markdownTextStyle {
                            FontWeight(.bold)
                            FontSize(22)
                            ForegroundColor(isDark ? .white : .primary)
                        }
                    Divider()
                }
                .markdownMargin(top: 20, bottom: 12)
            }
            .heading3 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(18)
                        ForegroundColor(isDark ? .white : .primary)
                    }
                    .markdownMargin(top: 16, bottom: 8)
            }
            .heading4 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(16)
                        ForegroundColor(isDark ? .white : .primary)
                    }
                    .markdownMargin(top: 12, bottom: 6)
            }
            .heading5 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontWeight(.medium)
                        FontSize(14)
                        ForegroundColor(isDark ? .white : .primary)
                    }
                    .markdownMargin(top: 10, bottom: 4)
            }
            .heading6 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontWeight(.medium)
                        FontSize(13)
                        ForegroundColor(isDark ? .white.opacity(0.7) : .secondary)
                    }
                    .markdownMargin(top: 8, bottom: 4)
            }
            // Code blocks
            .codeBlock { configuration in
                ScrollView(.horizontal, showsIndicators: true) {
                    configuration.label
                        .markdownTextStyle {
                            FontFamilyVariant(.monospaced)
                            FontSize(13)
                            ForegroundColor(isDark ? Color(red: 0.9, green: 0.9, blue: 0.9) : Color(red: 0.2, green: 0.2, blue: 0.2))
                        }
                        .padding(12)
                }
                .background(isDark
                    ? Color(nsColor: NSColor(white: 0.08, alpha: 1.0))
                    : Color(nsColor: NSColor(white: 0.93, alpha: 1.0)))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .markdownMargin(top: 8, bottom: 8)
            }
            // Inline code
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(13)
                ForegroundColor(isDark ? Color(red: 0.85, green: 0.6, blue: 0.95) : Color(red: 0.6, green: 0.2, blue: 0.7))
                BackgroundColor(isDark
                    ? Color(nsColor: NSColor(white: 0.18, alpha: 1.0))
                    : Color(nsColor: NSColor(white: 0.92, alpha: 1.0)))
            }
            // Block quotes
            .blockquote { configuration in
                HStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(isDark ? Color.white.opacity(0.2) : Color.gray.opacity(0.4))
                        .frame(width: 3)
                    configuration.label
                        .markdownTextStyle {
                            ForegroundColor(isDark ? .white.opacity(0.6) : .secondary)
                            FontSize(14)
                        }
                        .padding(.leading, 12)
                }
                .markdownMargin(top: 8, bottom: 8)
            }
            // Links
            .link {
                ForegroundColor(Color.accentColor)
            }
            // Strong
            .strong {
                FontWeight(.semibold)
            }
            // Tables
            .table { configuration in
                configuration.label
                    .markdownTableBorderStyle(.init(color: isDark ? .white.opacity(0.15) : .gray.opacity(0.3)))
                    .markdownTableBackgroundStyle(
                        .alternatingRows(
                            isDark
                                ? Color(nsColor: NSColor(white: 0.14, alpha: 1.0))
                                : Color(nsColor: NSColor(white: 0.96, alpha: 1.0)),
                            isDark
                                ? Color(nsColor: NSColor(white: 0.10, alpha: 1.0))
                                : Color(nsColor: NSColor(white: 1.0, alpha: 1.0))
                        )
                    )
                    .markdownMargin(top: 8, bottom: 8)
            }
            // Thematic break (horizontal rule)
            .thematicBreak {
                Divider()
                    .markdownMargin(top: 16, bottom: 16)
            }
            // List items
            .listItem { configuration in
                configuration.label
                    .markdownMargin(top: 4, bottom: 4)
            }
            // Paragraphs
            .paragraph { configuration in
                configuration.label
                    .markdownMargin(top: 4, bottom: 8)
            }
    }

    // MARK: - Focus Flash

    private func triggerFocusFlashAnimation() {
        focusFlashAnimationGeneration &+= 1
        let generation = focusFlashAnimationGeneration
        focusFlashOpacity = FocusFlashPattern.values.first ?? 0

        for segment in FocusFlashPattern.segments {
            DispatchQueue.main.asyncAfter(deadline: .now() + segment.delay) {
                guard focusFlashAnimationGeneration == generation else { return }
                withAnimation(focusFlashAnimation(for: segment.curve, duration: segment.duration)) {
                    focusFlashOpacity = segment.targetOpacity
                }
            }
        }
    }

    private func focusFlashAnimation(for curve: FocusFlashCurve, duration: TimeInterval) -> Animation {
        switch curve {
        case .easeIn:
            return .easeIn(duration: duration)
        case .easeOut:
            return .easeOut(duration: duration)
        }
    }
}

private struct MarkdownPointerObserver: NSViewRepresentable {
    let onPointerDown: () -> Void

    func makeNSView(context: Context) -> MarkdownPanelPointerObserverView {
        let view = MarkdownPanelPointerObserverView()
        view.onPointerDown = onPointerDown
        return view
    }

    func updateNSView(_ nsView: MarkdownPanelPointerObserverView, context: Context) {
        nsView.onPointerDown = onPointerDown
    }
}

final class MarkdownPanelPointerObserverView: NSView {
    var onPointerDown: (() -> Void)?
    private var eventMonitor: Any?
    private weak var forwardedMouseTarget: NSView?

    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        installEventMonitorIfNeeded()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard PaneFirstClickFocusSettings.isEnabled(),
              window?.isKeyWindow != true,
              bounds.contains(point) else { return nil }
        return self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        PaneFirstClickFocusSettings.isEnabled()
    }

    override func mouseDown(with event: NSEvent) {
        forwardMouseDown(event)
    }

    override func rightMouseDown(with event: NSEvent) {
        forwardMouseDown(event)
    }

    override func otherMouseDown(with event: NSEvent) {
        forwardMouseDown(event)
    }

    override func mouseDragged(with event: NSEvent) {
        forwardMouseDragged(event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        forwardMouseDragged(event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        forwardMouseDragged(event)
    }

    override func mouseUp(with event: NSEvent) {
        forwardMouseUp(event)
    }

    override func rightMouseUp(with event: NSEvent) {
        forwardMouseUp(event)
    }

    override func otherMouseUp(with event: NSEvent) {
        forwardMouseUp(event)
    }

    func shouldHandle(_ event: NSEvent) -> Bool {
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            break
        default:
            return false
        }
        guard
              let window,
              event.window === window,
              !isHiddenOrHasHiddenAncestor else { return false }
        if PaneFirstClickFocusSettings.isEnabled(), window.isKeyWindow != true {
            return false
        }
        let point = convert(event.locationInWindow, from: nil)
        return bounds.contains(point)
    }

    func handleEventIfNeeded(_ event: NSEvent) -> NSEvent {
        guard shouldHandle(event) else { return event }
        DispatchQueue.main.async { [weak self] in
            self?.onPointerDown?()
        }
        return event
    }

    private func installEventMonitorIfNeeded() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            self?.handleEventIfNeeded(event) ?? event
        }
    }

    private func forwardMouseDown(_ event: NSEvent) {
        onPointerDown?()
        forwardedMouseTarget = forwardedTarget(for: event)
        switch event.type {
        case .leftMouseDown:
            forwardedMouseTarget?.mouseDown(with: event)
        case .rightMouseDown:
            forwardedMouseTarget?.rightMouseDown(with: event)
        case .otherMouseDown:
            forwardedMouseTarget?.otherMouseDown(with: event)
        default:
            break
        }
    }

    private func forwardMouseDragged(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDragged:
            forwardedMouseTarget?.mouseDragged(with: event)
        case .rightMouseDragged:
            forwardedMouseTarget?.rightMouseDragged(with: event)
        case .otherMouseDragged:
            forwardedMouseTarget?.otherMouseDragged(with: event)
        default:
            break
        }
    }

    private func forwardMouseUp(_ event: NSEvent) {
        defer { forwardedMouseTarget = nil }
        switch event.type {
        case .leftMouseUp:
            forwardedMouseTarget?.mouseUp(with: event)
        case .rightMouseUp:
            forwardedMouseTarget?.rightMouseUp(with: event)
        case .otherMouseUp:
            forwardedMouseTarget?.otherMouseUp(with: event)
        default:
            break
        }
    }

    private func forwardedTarget(for event: NSEvent) -> NSView? {
        guard let window else {
#if DEBUG
            NSLog("MarkdownPanelPointerObserverView.forwardedTarget skipped, window=0 contentView=0")
#endif
            return nil
        }
        guard let contentView = window.contentView else {
#if DEBUG
            NSLog("MarkdownPanelPointerObserverView.forwardedTarget skipped, window=1 contentView=0")
#endif
            return nil
        }
        isHidden = true
        defer { isHidden = false }
        let point = contentView.convert(event.locationInWindow, from: nil)
        let target = contentView.hitTest(point)
        return target === self ? nil : target
    }
}

struct VncPanelView: View {
    @ObservedObject var panel: VncPanel
    let isFocused: Bool
    let isVisibleInUI: Bool
    let portalPriority: Int
    let onRequestPanelFocus: () -> Void

    @State private var focusFlashOpacity: Double = 0.0
    @State private var focusFlashAnimationGeneration: Int = 0
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case endpoint
        case username
        case password
    }

    private var connectButtonTitle: String {
        if panel.isAwaitingCredentials {
            return String(localized: "vnc.panel.sendCredentials", defaultValue: "Send Credentials")
        }
        if panel.connectionState == .connecting {
            return String(localized: "vnc.panel.connecting", defaultValue: "Connecting…")
        }
        if panel.isConnected {
            return String(localized: "vnc.panel.disconnect", defaultValue: "Disconnect")
        }
        return String(localized: "vnc.panel.connect", defaultValue: "Connect")
    }

    private var isConnectButtonDisabled: Bool {
        if panel.isConnected {
            return false
        }
        if panel.isAwaitingCredentials {
            let usernameReady = !panel.requiredCredentialFields.contains(.username) ||
                !panel.usernameInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let passwordReady = !panel.requiredCredentialFields.contains(.password) ||
                !panel.passwordInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return !(usernameReady && passwordReady)
        }
        return panel.endpointInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hostPickerTitle: String {
        String(localized: "vnc.panel.targets.button", defaultValue: "Hosts")
    }

    private var hasHostSuggestions: Bool {
        !panel.recentTargets.isEmpty || !panel.discoveredTargets.isEmpty
    }

    private func discoveredTargetTitle(_ target: VncDiscoveredTarget) -> String {
        let format = String(
            localized: "vnc.panel.targets.discoveredEntry",
            defaultValue: "%1$@ (%2$@)"
        )
        return String(format: format, locale: Locale.current, target.name, target.endpoint)
    }

    private var statusText: String {
        switch panel.connectionState {
        case .idle:
            return String(localized: "vnc.panel.status.idle", defaultValue: "Ready")
        case .connecting:
            return String(localized: "vnc.panel.status.connecting", defaultValue: "Connecting…")
        case .connected:
            return String(localized: "vnc.panel.status.connected", defaultValue: "Connected")
        case .disconnected:
            return String(localized: "vnc.panel.status.disconnected", defaultValue: "Disconnected")
        case .error:
            return String(localized: "vnc.panel.status.error", defaultValue: "Connection error")
        }
    }

    private var statusColor: Color {
        switch panel.connectionState {
        case .connected:
            return .green
        case .error:
            return .red
        default:
            return .secondary
        }
    }

    var body: some View {
        _ = portalPriority
        _ = isVisibleInUI

        return VStack(spacing: 0) {
            toolbar
            Divider()
            ZStack {
                if panel.usesNativeRenderer,
                   let nativeHostView = panel.nativeSessionHostView {
                    VncPanelNativeSessionRepresentable(hostView: nativeHostView)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityIdentifier("VNCPanel.Content.\(panel.id.uuidString)")
                        .background(Color.black)
                        .overlay {
                            if isVisibleInUI {
                                MarkdownPointerObserver(onPointerDown: onRequestPanelFocus)
                            }
                        }
                } else if let webView = panel.webView {
                    VncPanelWebViewRepresentable(webView: webView)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityIdentifier("VNCPanel.Content.\(panel.id.uuidString)")
                        .background(Color.black)
                } else {
                    Color.black
                }

                if panel.connectionState != .connected {
                    disconnectedOverlay
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: NSColor.black))
        .overlay {
            RoundedRectangle(cornerRadius: FocusFlashPattern.ringCornerRadius)
                .stroke(cmuxAccentColor().opacity(focusFlashOpacity), lineWidth: 3)
                .shadow(color: cmuxAccentColor().opacity(focusFlashOpacity * 0.35), radius: 10)
                .padding(FocusFlashPattern.ringInset)
                .allowsHitTesting(false)
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .webViewDidReceiveClick).filter { [weak panel] note in
                guard let panel, !panel.usesNativeRenderer else { return false }
                guard let panelWebView = panel.webView else { return false }
                guard let webView = note.object as? CmuxWebView else { return false }
                return webView === panelWebView
            }
        ) { _ in
            if !isFocused {
                onRequestPanelFocus()
            }
        }
        .onChange(of: panel.focusFlashToken) { _ in
            triggerFocusFlashAnimation()
        }
        .onChange(of: panel.endpointFocusRequestID) { _ in
            focusedField = .endpoint
        }
        .onChange(of: panel.usernameFocusRequestID) { _ in
            focusedField = .username
        }
        .onChange(of: panel.passwordFocusRequestID) { _ in
            focusedField = .password
        }
        .onChange(of: panel.connectionState) { state in
            if state == .connected, isFocused {
                panel.focus()
            }
        }
        .onChange(of: isFocused) { focused in
            if !panel.usesNativeRenderer, let webView = panel.webView {
                webView.allowsFirstResponderAcquisition = focused
            }
            if focused {
                if panel.isConnected {
                    panel.focus()
                } else {
                    focusMostUsefulField()
                }
            }
        }
        .onAppear {
            if !panel.usesNativeRenderer, let webView = panel.webView {
                webView.allowsFirstResponderAcquisition = isFocused
            }
            if isFocused {
                if panel.isConnected {
                    panel.focus()
                } else {
                    focusMostUsefulField()
                }
            }
        }
    }

    private var toolbar: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                TextField(
                    String(localized: "vnc.panel.target.placeholder", defaultValue: "Host or host:port"),
                    text: $panel.endpointInput
                )
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .endpoint)
                .onSubmit { connectOrDisconnect() }
                .accessibilityIdentifier("VNCPanel.Endpoint.\(panel.id.uuidString)")

                Menu(hostPickerTitle) {
                    if panel.recentTargets.isEmpty && panel.discoveredTargets.isEmpty {
                        Text(String(localized: "vnc.panel.targets.empty", defaultValue: "No recent or discovered hosts"))
                    }
                    if !panel.recentTargets.isEmpty {
                        Section(String(localized: "vnc.panel.targets.recent", defaultValue: "Recent")) {
                            ForEach(panel.recentTargets, id: \.self) { target in
                                Button(target) {
                                    panel.chooseEndpointSuggestion(target)
                                }
                            }
                        }
                    }
                    if !panel.discoveredTargets.isEmpty {
                        Section(String(localized: "vnc.panel.targets.discovered", defaultValue: "Discovered")) {
                            ForEach(panel.discoveredTargets) { target in
                                Button(discoveredTargetTitle(target)) {
                                    panel.chooseEndpointSuggestion(target.endpoint)
                                }
                            }
                        }
                    }
                }
                .disabled(!hasHostSuggestions)

                TextField(
                    String(localized: "vnc.panel.username.placeholder", defaultValue: "Username (optional)"),
                    text: $panel.usernameInput
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 170)
                .focused($focusedField, equals: .username)
                .onSubmit { connectOrDisconnect() }
                .accessibilityIdentifier("VNCPanel.Username.\(panel.id.uuidString)")

                SecureField(
                    String(localized: "vnc.panel.password.placeholder", defaultValue: "Password (optional)"),
                    text: $panel.passwordInput
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .focused($focusedField, equals: .password)
                .onSubmit { connectOrDisconnect() }
                .accessibilityIdentifier("VNCPanel.Password.\(panel.id.uuidString)")

                Button(connectButtonTitle) {
                    connectOrDisconnect()
                }
                .disabled(isConnectButtonDisabled)

                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(statusColor)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }

            if let detail = panel.lastErrorDetail,
               !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(2)
            } else if panel.isAwaitingCredentials {
                Text(
                    String(
                        localized: "vnc.panel.credentials.prompt",
                        defaultValue: "Server requested credentials. Enter required fields, then send."
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(nsColor: NSColor.windowBackgroundColor))
    }

    private var disconnectedOverlay: some View {
        VStack(spacing: 8) {
            Image(systemName: "display")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text(
                String(
                    localized: "vnc.panel.overlay.title",
                    defaultValue: "Connect to a VNC server"
                )
            )
            .font(.headline)
            .foregroundStyle(.primary)
            Text(
                String(
                    localized: "vnc.panel.overlay.subtitle",
                    defaultValue: "Enter a host and port above, then click Connect."
                )
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func connectOrDisconnect() {
        if panel.isConnected {
            panel.disconnect()
            return
        }
        if panel.isAwaitingCredentials {
            guard !isConnectButtonDisabled else { return }
            panel.submitCredentials()
            return
        }
        if panel.connectionState == .connecting {
            panel.disconnect()
            return
        }
        guard !isConnectButtonDisabled else { return }
        panel.connect()
    }

    private func focusMostUsefulField() {
        if panel.endpointInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            focusedField = .endpoint
            return
        }
        if panel.isAwaitingCredentials {
            if panel.requiredCredentialFields.contains(.username),
               panel.usernameInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                focusedField = .username
                return
            }
            focusedField = .password
            return
        }
        focusedField = .endpoint
    }

    private func triggerFocusFlashAnimation() {
        focusFlashAnimationGeneration &+= 1
        let generation = focusFlashAnimationGeneration
        focusFlashOpacity = FocusFlashPattern.values.first ?? 0

        for segment in FocusFlashPattern.segments {
            DispatchQueue.main.asyncAfter(deadline: .now() + segment.delay) {
                guard focusFlashAnimationGeneration == generation else { return }
                withAnimation(focusFlashAnimation(for: segment.curve, duration: segment.duration)) {
                    focusFlashOpacity = segment.targetOpacity
                }
            }
        }
    }

    private func focusFlashAnimation(for curve: FocusFlashCurve, duration: TimeInterval) -> Animation {
        switch curve {
        case .easeIn:
            return .easeIn(duration: duration)
        case .easeOut:
            return .easeOut(duration: duration)
        }
    }
}

private struct VncPanelNativeSessionRepresentable: NSViewRepresentable {
    let hostView: NSView

    func makeNSView(context: Context) -> NSView {
        hostView
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        _ = nsView
    }
}

private struct VncPanelWebViewRepresentable: NSViewRepresentable {
    let webView: CmuxWebView

    func makeNSView(context: Context) -> CmuxWebView {
        webView
    }

    func updateNSView(_ nsView: CmuxWebView, context: Context) {
        _ = nsView
    }
}
