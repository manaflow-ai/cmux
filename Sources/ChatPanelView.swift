import SwiftUI
import AppKit

struct ChatPanelView: View {
    @ObservedObject var chatService: ChatService
    let onHide: () -> Void

    @State private var inputText = ""
    @State private var apiKeyDraft = ""
    @State private var settingsProvider: ChatService.Provider = .claude
    @State private var modelDraft = ""
    @State private var isShowingSettings = false
    @FocusState private var isInputFocused: Bool
    @FocusState private var isApiKeyFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            conversationView
        }
        .background(panelBackground)
        .frame(width: ChatPanelMetrics.panelWidth)
        .background(ChatPanelHitTestMarker())
        .sheet(isPresented: $isShowingSettings) {
            settingsSheet
        }
        .onAppear {
            settingsProvider = chatService.selectedProvider
            apiKeyDraft = chatService.apiKey
            modelDraft = chatService.selectedModel
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .foregroundStyle(.secondary)
                .font(.system(size: 13))
            Text(String(localized: "chatPanel.title", defaultValue: "AI Chat"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
            Text(chatService.selectedProvider.displayName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                chatService.clearMessages()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(String(localized: "chatPanel.clearChat", defaultValue: "Clear Chat"))

            Button {
                openSettings(for: chatService.selectedProvider)
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(String(localized: "chatPanel.settings", defaultValue: "Chat Settings"))

            Button {
                onHide()
            } label: {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(String(localized: "chatPanel.hide", defaultValue: "Hide Chat"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Settings

    private var settingsSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(String(localized: "chatPanel.settings.title", defaultValue: "Chat Settings"))
                    .font(.headline)
                Spacer()
            }

            ScrollView(.horizontal, showsIndicators: false) {
                Picker(String(localized: "chatPanel.provider", defaultValue: "Provider"), selection: $settingsProvider) {
                    ForEach(ChatService.Provider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize(horizontal: true, vertical: false)
            }
            .onChange(of: settingsProvider) { _, provider in
                apiKeyDraft = chatService.apiKey(for: provider)
                modelDraft = chatService.model(for: provider)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "chatPanel.apiKey.label", defaultValue: "API Key"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                SecureField(settingsProvider.apiKeyPlaceholder, text: $apiKeyDraft)
                    .textFieldStyle(.roundedBorder)
                    .focused($isApiKeyFocused)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "chatPanel.model.label", defaultValue: "Model"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Picker(String(localized: "chatPanel.model.label", defaultValue: "Model"), selection: $modelDraft) {
                    ForEach(chatService.modelOptions(for: settingsProvider), id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 8) {
                Spacer()
                Button(String(localized: "common.cancel", defaultValue: "Cancel")) {
                    isShowingSettings = false
                }
                .buttonStyle(.bordered)

                Button(String(localized: "chatPanel.apiKey.save", defaultValue: "Save")) {
                    let trimmed = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    chatService.selectedProvider = settingsProvider
                    chatService.setApiKey(trimmed, for: settingsProvider)
                    chatService.setModel(modelDraft, for: settingsProvider)
                    apiKeyDraft = ""
                    isShowingSettings = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 360, idealWidth: 520, maxWidth: 720)
        .frame(minHeight: 250)
    }

    // MARK: - Conversation

    private var conversationView: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if chatService.messages.isEmpty {
                            emptyState
                        } else {
                            ForEach(chatService.messages) { message in
                                MessageBubble(message: message, colorScheme: colorScheme)
                                    .id(message.id)
                            }
                        }
                        if let error = chatService.streamingError {
                            errorBanner(error)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                }
                .onChange(of: chatService.messages.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
                .onChange(of: chatService.messages.last?.content) { _, _ in
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }

            Divider()
            inputArea
        }
    }

    private func errorBanner(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.red)
                .font(.system(size: 12))
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Input area

    private var inputArea: some View {
        VStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    ChatTextEditor(text: $inputText, onSubmit: sendMessage)
                    if inputText.isEmpty {
                        Text(inputPlaceholder)
                            .font(.system(size: 13))
                            .foregroundStyle(Color(white: 0.55))
                            .padding(.leading, 10)
                            .padding(.top, 8)
                            .allowsHitTesting(false)
                    }
                }
                .frame(minHeight: 34, maxHeight: 120)
                .focused($isInputFocused)

                if chatService.isStreaming {
                    Button {
                        chatService.cancelStreaming()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(.red.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        sendMessage()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(
                                inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    ? Color.secondary.opacity(0.4)
                                    : cmuxAccentColor()
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            providerAndModelPicker
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var providerAndModelPicker: some View {
        HStack(spacing: 6) {
            Image(systemName: chatService.hasApiKey ? "sparkles" : "key")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Picker(String(localized: "chatPanel.provider", defaultValue: "Provider"), selection: Binding(
                get: { chatService.selectedProvider },
                set: { provider in
                    chatService.selectedProvider = provider
                    if !chatService.hasApiKey {
                        openSettings(for: provider, focusApiKey: true)
                    }
                }
            )) {
                ForEach(ChatService.Provider.allCases) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .disabled(chatService.isStreaming)

            Picker(String(localized: "chatPanel.model.label", defaultValue: "Model"), selection: Binding(
                get: { chatService.selectedModel },
                set: { chatService.setModel($0, for: chatService.selectedProvider) }
            )) {
                ForEach(chatService.modelOptions(for: chatService.selectedProvider), id: \.self) { model in
                    Text(model).tag(model)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .disabled(chatService.isStreaming)
            Spacer()
        }
        .frame(height: 22)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: chatService.hasApiKey ? "sparkles" : "key")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(
                chatService.hasApiKey
                    ? String(localized: "chatPanel.empty.ready", defaultValue: "Ask \(chatService.selectedProvider.displayName) anything.")
                    : String(localized: "chatPanel.empty.needsKey", defaultValue: "Choose a provider and add an API key to start chatting.")
            )
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            if !chatService.hasApiKey {
                Button(String(localized: "chatPanel.settings.open", defaultValue: "Open Settings")) {
                    openSettings(for: chatService.selectedProvider, focusApiKey: true)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity)
    }

    private var inputPlaceholder: String {
        if chatService.hasApiKey {
            return String(localized: "chatPanel.input.placeholder", defaultValue: "Message...")
        }
        return String(localized: "chatPanel.input.needsKey", defaultValue: "Add an API key in settings...")
    }

    private func sendMessage() {
        guard chatService.hasApiKey else {
            openSettings(for: chatService.selectedProvider, focusApiKey: true)
            return
        }
        let text = inputText
        inputText = ""
        chatService.sendMessage(text)
    }

    private func openSettings(for provider: ChatService.Provider, focusApiKey: Bool = false) {
        settingsProvider = provider
        apiKeyDraft = chatService.apiKey(for: provider)
        modelDraft = chatService.model(for: provider)
        isShowingSettings = true
        guard focusApiKey else { return }
        DispatchQueue.main.async {
            isApiKeyFocused = true
        }
    }

    // MARK: - Background

    private var panelBackground: Color {
        colorScheme == .dark
            ? Color(nsColor: NSColor(white: 0.12, alpha: 1.0))
            : Color(nsColor: NSColor(white: 0.97, alpha: 1.0))
    }
}

// MARK: - Hit Test Marker

enum ChatPanelHitTestRegistry {
    private struct MarkerEntry {
        let windowId: ObjectIdentifier
        let rectInWindow: NSRect
    }

    private static var entriesByMarkerId: [ObjectIdentifier: MarkerEntry] = [:]
    private static var focusOwnerTable: NSHashTable<NSView> = .weakObjects()

    static func update(marker: NSView) {
        let markerId = ObjectIdentifier(marker)
        guard let window = marker.window else {
            entriesByMarkerId.removeValue(forKey: markerId)
            return
        }
        let rect = marker.convert(marker.bounds, to: nil)
        entriesByMarkerId[markerId] = MarkerEntry(
            windowId: ObjectIdentifier(window),
            rectInWindow: rect
        )
    }

    static func remove(marker: NSView) {
        entriesByMarkerId.removeValue(forKey: ObjectIdentifier(marker))
    }

    static func contains(windowPoint: NSPoint, in window: NSWindow?) -> Bool {
        guard let window else { return false }
        let windowId = ObjectIdentifier(window)
        return entriesByMarkerId.values.contains {
            $0.windowId == windowId && $0.rectInWindow.contains(windowPoint)
        }
    }

    static func registerFocusOwner(_ view: NSView) {
        focusOwnerTable.add(view)
    }

    static func unregisterFocusOwner(_ view: NSView) {
        focusOwnerTable.remove(view)
    }

    /// Returns true if the responder is (or is a descendant of) a chat panel input view.
    static func ownsFocusResponder(_ responder: NSResponder) -> Bool {
        guard let view = responder as? NSView else { return false }
        for owner in focusOwnerTable.allObjects {
            if view === owner || view.isDescendant(of: owner) {
                return true
            }
        }
        return false
    }
}

private struct ChatPanelHitTestMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> MarkerView {
        MarkerView(frame: .zero)
    }

    func updateNSView(_ nsView: MarkerView, context: Context) {
        nsView.refreshRegisteredFrame()
    }

    final class MarkerView: NSView {
        override var isOpaque: Bool { false }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            refreshRegisteredFrame()
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            refreshRegisteredFrame()
        }

        override func setFrameOrigin(_ newOrigin: NSPoint) {
            super.setFrameOrigin(newOrigin)
            refreshRegisteredFrame()
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        deinit {
            ChatPanelHitTestRegistry.remove(marker: self)
        }

        func refreshRegisteredFrame() {
            ChatPanelHitTestRegistry.update(marker: self)
        }
    }
}

// MARK: - Message Bubble

private struct MessageBubble: View {
    let message: ChatService.Message
    let colorScheme: ColorScheme

    var isUser: Bool { message.role == .user }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 32) }
            Text(message.content.isEmpty && !isUser ? "▌" : message.content)
                .font(.system(size: 13))
                .foregroundStyle(isUser ? Color.white : (colorScheme == .dark ? Color.white.opacity(0.9) : Color.primary))
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    isUser
                        ? cmuxAccentColor()
                        : (colorScheme == .dark
                            ? Color(nsColor: NSColor(white: 0.22, alpha: 1.0))
                            : Color(nsColor: NSColor(white: 0.90, alpha: 1.0))),
                    in: RoundedRectangle(cornerRadius: 12)
                )
                .fixedSize(horizontal: false, vertical: true)
            if !isUser { Spacer(minLength: 32) }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }
}

// MARK: - Chat Text Editor

private struct ChatTextEditor: NSViewRepresentable {
    @Binding var text: String
    let onSubmit: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollablePlainDocumentContentTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }

        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.font = NSFont.systemFont(ofSize: 13)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = true
        textView.textContainerInset = NSSize(width: 4, height: 6)
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder

        ChatPanelHitTestRegistry.registerFocusOwner(scrollView)
        return scrollView
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        ChatPanelHitTestRegistry.unregisterFocusOwner(nsView)
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.onSubmit = onSubmit

        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let bgColor = isDark ? NSColor(white: 0.18, alpha: 1.0) : NSColor.white
        textView.backgroundColor = bgColor
        scrollView.backgroundColor = bgColor
        scrollView.drawsBackground = true

        if textView.string != text {
            let loc = min(textView.selectedRange().location, (text as NSString).length)
            textView.string = text
            textView.setSelectedRange(NSRange(location: loc, length: 0))
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        var onSubmit: () -> Void

        init(text: Binding<String>, onSubmit: @escaping () -> Void) {
            _text = text
            self.onSubmit = onSubmit
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text = textView.string
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                let shiftDown = NSEvent.modifierFlags.contains(.shift)
                if !shiftDown {
                    onSubmit()
                    return true
                }
            }
            return false
        }
    }
}

enum ChatPanelMetrics {
    static let panelWidth: CGFloat = 420
    static let minPanelWidth: CGFloat = 320
    static let maxPanelWidth: CGFloat = 480
}
