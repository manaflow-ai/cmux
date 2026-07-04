import CmuxAgentChat
import SwiftUI

#if canImport(UIKit)
import Accessibility
import UIKit
#endif

/// The full conversation surface: header state, transcript, typing
/// indicator, and the keyboard-attached composer.
///
/// The host creates the ``ChatConversationStore`` (with its platform event
/// source) and hands it over; this screen owns presentation state only
/// (drafts, attachments).
public struct ChatScreen: View {
    @State private var store: ChatConversationStore
    @State private var renderer = ChatMarkdownRenderer()
    @State private var contentCache = ChatContentCache()
    @State private var selectedBlockDetail: ChatBlockDetail?

    @Binding private var draft: String
    private let accessoryLeadingShortcuts: [ChatAccessoryShortcut]
    private let accessoryShortcuts: [ChatAccessoryShortcut]
    private let onOpenTerminal: () -> Void
    private let providesOwnChrome: Bool
    private let runsStoreTask: Bool

    /// Creates the screen.
    ///
    /// - Parameters:
    ///   - store: The conversation store, constructed by the host with its
    ///     platform ``ChatEventSource``.
    ///   - onOpenTerminal: Opens the session's raw terminal surface (the
    ///     escape hatch); the host owns that navigation.
    ///   - draft: Host-owned composer draft, so a dismissed cover keeps
    ///     the half-typed prompt. Pass `.constant("")` to opt out.
    ///   - accessoryLeadingShortcuts: Host-provided fixed composer shortcut
    ///     row items.
    ///   - accessoryShortcuts: Host-provided composer shortcut row items.
    ///   - providesOwnChrome: When `true` (default, standalone use) the
    ///     screen sets its own navigation title, session-state header, and
    ///     Open-Terminal button. Pass `false` when embedded in a host that
    ///     supplies its own navigation chrome (the in-place workspace
    ///     toggle), so the two don't fight and drop the header.
    ///   - runsStoreTask: Whether this screen should run the conversation
    ///     subscription. Pass `false` when a parent keeps the store warm while
    ///     the chat UI is not mounted.
    public init(
        store: ChatConversationStore,
        draft: Binding<String> = .constant(""),
        accessoryLeadingShortcuts: [ChatAccessoryShortcut] = [],
        accessoryShortcuts: [ChatAccessoryShortcut] = [],
        providesOwnChrome: Bool = true,
        runsStoreTask: Bool = true,
        onOpenTerminal: @escaping () -> Void
    ) {
        _store = State(initialValue: store)
        _draft = draft
        self.accessoryLeadingShortcuts = accessoryLeadingShortcuts
        self.accessoryShortcuts = accessoryShortcuts
        self.providesOwnChrome = providesOwnChrome
        self.runsStoreTask = runsStoreTask
        self.onOpenTerminal = onOpenTerminal
    }

    public var body: some View {
        ZStack(alignment: .top) {
            chatLayout
            // On iOS 26 `chatLayout` underlaps the top chrome
            // (`chatTopBarUnderlapContainer` ignores the top safe area so the
            // native scroll-edge effect can blend transcript rows into the
            // bar). The error toast must stay *below* the navigation bar, so it
            // lives as a ZStack sibling that still respects the top safe area —
            // an `.overlay` on the underlapped layout would inherit the
            // underlap and render the banner under the bar.
            errorBanner
        }
        .animation(.snappy(duration: 0.2), value: store.lastErrorDescription)
        .animation(.snappy(duration: 0.22), value: store.agentState == .ended)
        .modifier(ChatScreenChrome(
            store: store,
            providesOwnChrome: providesOwnChrome,
            onOpenTerminal: onOpenTerminal
        ))
        .sheet(item: $selectedBlockDetail) { detail in
            ChatBlockDetailSheetView(detail: detail)
        }
        .task {
            guard runsStoreTask else { return }
            await store.run()
        }
        #if canImport(UIKit)
        .onChange(of: store.rows.last?.id) { announceLatestAgentProse() }
        .onChange(of: store.lastErrorDescription) { announceLastError() }
        #endif
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let error = store.lastErrorDescription {
            Text(error)
                .font(.caption)
                .foregroundStyle(.white)
                .lineLimit(2)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.red.opacity(0.92), in: .capsule)
                .padding(.top, 4)
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityIdentifier("ChatErrorBanner")
                .onTapGesture { store.dismissError() }
                // Swipe the toast up to dismiss (it animates out via the
                // move(edge: .top) transition), in addition to tap and the
                // bounded auto-dismiss below.
                .gesture(
                    DragGesture(minimumDistance: 8)
                        .onEnded { value in
                            if value.translation.height < -8 { store.dismissError() }
                        }
                )
                // Bounded auto-dismiss: the view is keyed on the error text,
                // so a new error restarts the timer subscription.
                .id(error)
                .onReceive(Timer.publish(every: 8, on: .main, in: .common).autoconnect()) { _ in
                    store.dismissError()
                }
        }
    }

    @ViewBuilder
    private var chatLayout: some View {
        #if os(iOS)
        ChatKeyboardTrackingContainer(
            transcript: transcriptContent,
            composer: composerContent,
            showsComposer: store.agentState != .ended
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .chatTopBarUnderlapContainer()
        .ignoresSafeArea(.keyboard, edges: .bottom)
        #else
        VStack(spacing: 0) {
            transcriptContent
            composerContent
        }
        #endif
    }

    private var transcriptContent: some View {
        ChatTranscriptListView(
            rows: store.rows,
            agentState: store.agentState,
            hasMoreHistory: store.hasMoreHistory,
            hasLoadedInitialHistory: store.hasLoadedInitialHistory,
            initialLoadFailed: store.initialLoadFailed,
            historyTruncatedAtHead: store.historyTruncatedAtHead,
            actions: rowActions,
            onReachTop: { Task { await store.loadOlder() } },
            onRetryInitialLoad: { Task { await store.retryInitialLoad() } }
        )
        .environment(\.chatMarkdownRenderer, renderer)
        .environment(\.chatContentCache, contentCache)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .layoutPriority(0)
    }

    @ViewBuilder
    private var composerContent: some View {
        // A past/ended coding-agent session is read-only: keep the transcript
        // history but drop the text field and control buttons.
        if store.agentState != .ended {
            ChatComposerView(
                agentState: store.agentState,
                agentKind: store.descriptor.agentKind,
                isTerminal: store.descriptor.kind == .terminal,
                isConnected: store.isConnected,
                accessoryLeadingShortcuts: accessoryLeadingShortcuts,
                accessoryShortcuts: accessoryShortcuts,
                draft: $draft,
                onSend: { text, attachments in
                    Task { await store.send(text: text, attachments: attachments) }
                },
                onInterrupt: { hard in
                    Task { await store.interrupt(hard: hard) }
                },
                onOpenTerminal: onOpenTerminal
            )
            #if os(iOS)
            .layoutPriority(1)
            #endif
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    #if canImport(UIKit)
    /// Speaks newly arrived agent prose so VoiceOver users hear replies
    /// without re-scanning the transcript.
    private func announceLatestAgentProse() {
        guard UIAccessibility.isVoiceOverRunning,
              case .message(let snapshot)? = store.rows.last,
              snapshot.message.role == .agent,
              case .prose(let prose) = snapshot.message.kind
        else { return }
        AccessibilityNotification.Announcement(prose.text).post()
    }

    /// Speaks the error banner's text when an error surfaces.
    private func announceLastError() {
        guard UIAccessibility.isVoiceOverRunning,
              let error = store.lastErrorDescription
        else { return }
        AccessibilityNotification.Announcement(error).post()
    }
    #endif

    private var rowActions: ChatRowActions {
        ChatRowActions(
            answerOption: { index in
                Task { await store.answer(optionIndex: index) }
            },
            retryPending: { id in
                Task { await store.retry(pendingID: id) }
            },
            discardPending: { id in
                store.discard(pendingID: id)
            },
            openTerminal: onOpenTerminal,
            showMessageDetail: { message in
                selectedBlockDetail = ChatBlockDetail.make(message: message)
            },
            showTerminalCommandDetail: { block in
                selectedBlockDetail = ChatBlockDetail.make(block: block)
            },
            showCodeBlockDetail: { code, language in
                selectedBlockDetail = ChatBlockDetail.codeBlock(
                    id: "code-\(code.hashValue)-\(language ?? "")",
                    code: code,
                    language: language
                )
            }
        )
    }
}

#if os(iOS)
private extension View {
    @ViewBuilder
    func chatTopBarUnderlapContainer() -> some View {
        if #available(iOS 26.0, *) {
            ignoresSafeArea(.container, edges: .top)
        } else {
            self
        }
    }
}
#endif

/// Standalone navigation chrome for ``ChatScreen``: title, session-state
/// header, and the Open-Terminal button. Suppressed when the host supplies
/// its own chrome (the in-place workspace toggle), so a nested second
/// toolbar can't drop the header.
private struct ChatScreenChrome: ViewModifier {
    let store: ChatConversationStore
    let providesOwnChrome: Bool
    let onOpenTerminal: () -> Void

    func body(content: Content) -> some View {
        #if os(iOS)
        if providesOwnChrome {
            content
                .navigationTitle(store.descriptor.title ?? store.descriptor.agentKind.displayName)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        ChatSessionHeaderView(
                            descriptor: store.descriptor,
                            agentState: store.agentState,
                            isConnected: store.isConnected
                        )
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(action: onOpenTerminal) {
                            Image(systemName: "terminal")
                        }
                        .accessibilityLabel(
                            String(
                                localized: "chat.open_terminal.accessibility",
                                defaultValue: "Open terminal",
                                bundle: .module
                            )
                        )
                    }
                }
        } else {
            content
        }
        #else
        content
        #endif
    }
}
