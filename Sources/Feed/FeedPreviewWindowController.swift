import CmuxFoundation
#if DEBUG
import AppKit
import CMUXAgentLaunch

/// Debug-only window that renders every Feed item kind and state against
/// synthetic fixtures using the same native card implementation as the sidebar.
@MainActor
final class FeedPreviewWindowController: ReleasingWindowController {
    static let shared = FeedPreviewWindowController()

    override func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 820),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "debug.feedPreview.title", defaultValue: "Feed Preview")
        window.identifier = NSUserInterfaceItemIdentifier("cmux.feedPreview")
        window.minSize = NSSize(width: 420, height: 500)
        window.center()
        window.contentView = FeedPreviewRootView()
        return window
    }

    func show() {
        showManagedWindow(activateApplication: true)
    }
}

@MainActor
private final class FeedPreviewRootView: NSView {
    private let contentStack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let toolbar = makeToolbar()
        let separator = NSBox()
        separator.boxType = .separator
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 20
        contentStack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: document.topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
        ])
        scrollView.documentView = document

        let rootStack = NSStackView(views: [toolbar, separator, scrollView])
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 0
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rootStack)
        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            rootStack.topAnchor.constraint(equalTo: topAnchor),
            rootStack.bottomAnchor.constraint(equalTo: bottomAnchor),
            toolbar.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            separator.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            scrollView.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
        ])

        for kind in FeedPreviewFixtures.Kind.allCases {
            addSection(for: kind)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func makeToolbar() -> NSView {
        let title = NSTextField(
            labelWithString: String(
                localized: "debug.feedPreview.subtitle",
                defaultValue: "Feed Preview · all kinds + states"
            )
        )
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = .secondaryLabelColor
        let inject = NSButton(
            title: String(localized: "debug.feedPreview.injectAll", defaultValue: "Inject all into Feed"),
            target: self,
            action: #selector(injectAllIntoLiveStore)
        )
        inject.bezelStyle = .rounded
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [title, spacer, inject])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        return stack
    }

    private func addSection(for kind: FeedPreviewFixtures.Kind) {
        let section = NSStackView()
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 8
        let heading = NSTextField(labelWithString: kind.label.uppercased())
        heading.font = .systemFont(ofSize: 11, weight: .heavy)
        heading.textColor = .labelColor.withAlphaComponent(0.9)
        section.addArrangedSubview(heading)
        for item in FeedPreviewFixtures.allStates(for: kind) {
            let caption = NSTextField(labelWithString: statusLabel(for: item).uppercased())
            caption.font = .systemFont(ofSize: 9, weight: .bold)
            caption.textColor = statusColor(for: item)
            section.addArrangedSubview(caption)
            let card = FeedNativeCardView()
            let state = FeedNativeCardState()
            card.configure(
                snapshot: FeedNativeItemSnapshot(
                    item: item,
                    userPromptEcho: String(
                        localized: "debug.feedPreview.samplePrompt",
                        defaultValue: "make a plan and ask me for permission requests…"
                    )
                ),
                state: state,
                actions: FeedPreviewActions.make(),
                isSelected: false,
                isKeyboardActive: false,
                showsDivider: false,
                onSelect: { _ in },
                onActivate: {},
                onStateChange: {}
            )
            card.translatesAutoresizingMaskIntoConstraints = false
            section.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
            card.heightAnchor.constraint(equalToConstant: card.height(fittingWidth: 580)).isActive = true
        }
        section.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(section)
        section.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
    }

    private func statusLabel(for item: WorkstreamItem) -> String {
        switch item.status {
        case .pending: return String(localized: "debug.feedPreview.pending", defaultValue: "Pending")
        case .resolved: return String(localized: "debug.feedPreview.resolved", defaultValue: "Resolved")
        case .expired: return String(localized: "debug.feedPreview.expired", defaultValue: "Expired")
        case .telemetry: return String(localized: "debug.feedPreview.telemetry", defaultValue: "Telemetry")
        }
    }

    private func statusColor(for item: WorkstreamItem) -> NSColor {
        switch item.status {
        case .pending: return .systemOrange
        case .resolved: return .systemGreen
        case .expired: return .secondaryLabelColor
        case .telemetry: return .systemBlue
        }
    }

    @objc private func injectAllIntoLiveStore() {
        guard let store = FeedCoordinator.shared.store else { return }
        for kind in FeedPreviewFixtures.Kind.allCases {
            for item in FeedPreviewFixtures.allStates(for: kind) {
                store.ingest(FeedPreviewFixtures.wireEvent(for: item))
            }
        }
    }
}

private enum FeedPreviewActions {
    static func make() -> FeedNativeRowActions {
        FeedNativeRowActions(
            approvePermission: { id, mode in print("preview.permission \(id) \(mode)") },
            replyQuestion: { id, selections in print("preview.question \(id) \(selections)") },
            approveExitPlan: { id, mode, feedback in
                print("preview.exitPlan \(id) \(mode) feedback=\(feedback ?? "nil")")
            },
            jump: { workstream in print("preview.jump \(workstream)") },
            sendText: { workstream, value in print("preview.sendText \(workstream) \(value)") }
        )
    }
}

// MARK: - Fixtures

enum FeedPreviewFixtures {
    enum Kind: String, CaseIterable, Identifiable {
        case permission, exitPlan, question, todos, toolUse, userPrompt
        var id: String { rawValue }
        var label: String {
            switch self {
            case .permission: return "Permission request"
            case .exitPlan: return "Plan mode"
            case .question: return "AskUserQuestion (multi)"
            case .todos: return "TodoWrite"
            case .toolUse: return "Tool use (telemetry)"
            case .userPrompt: return "User prompt (telemetry)"
            }
        }
    }

    enum StateChoice: String, CaseIterable, Identifiable {
        case pending, resolved, expired, all
        var id: String { rawValue }
        var label: String {
            switch self {
            case .pending: return "Pending"
            case .resolved: return "Resolved"
            case .expired: return "Expired"
            case .all: return "Pending + Resolved + Expired"
            }
        }
    }

    static func item(kind: Kind, state: StateChoice) -> WorkstreamItem {
        let createdAt = Date().addingTimeInterval(-30)
        let cwd = "/Users/lawrence/fun/cmuxterm-hq"
        let (workstreamKind, payload): (WorkstreamKind, WorkstreamPayload) = makePayload(kind: kind)
        let statusValue: WorkstreamStatus = {
            if !workstreamKind.isActionable { return .telemetry }
            switch state {
            case .pending: return .pending
            case .resolved: return .resolved(sampleDecision(for: kind), at: Date())
            case .expired: return .expired(at: Date())
            case .all: return .pending
            }
        }()
        return WorkstreamItem(
            id: UUID(),
            workstreamId: "claude-preview-\(kind.rawValue)-\(state.rawValue)",
            source: .claude,
            kind: workstreamKind,
            createdAt: createdAt,
            updatedAt: createdAt,
            cwd: cwd,
            title: titleHint(for: kind),
            status: statusValue,
            payload: payload
        )
    }

    static func allStates(for kind: Kind) -> [WorkstreamItem] {
        let workstreamKind = makePayload(kind: kind).0
        guard workstreamKind.isActionable else {
            return [item(kind: kind, state: .pending)]
        }
        return [
            item(kind: kind, state: .pending),
            item(kind: kind, state: .resolved),
            item(kind: kind, state: .expired),
        ]
    }

    static func wireEvent(for item: WorkstreamItem) -> WorkstreamEvent {
        let eventName: WorkstreamEvent.HookEventName
        switch item.kind {
        case .permissionRequest: eventName = .permissionRequest
        case .exitPlan: eventName = .exitPlanMode
        case .question: eventName = .askUserQuestion
        case .todos: eventName = .todoWrite
        case .userPrompt: eventName = .userPromptSubmit
        default: eventName = .preToolUse
        }
        return WorkstreamEvent(
            sessionId: item.workstreamId,
            hookEventName: eventName,
            source: item.source.rawValue,
            cwd: item.cwd,
            toolName: item.title,
            toolInputJSON: nil,
            requestId: item.workstreamId,
            ppid: Int(getpid()),
            receivedAt: item.createdAt
        )
    }

    private static func makePayload(kind: Kind) -> (WorkstreamKind, WorkstreamPayload) {
        switch kind {
        case .permission:
            return (.permissionRequest, .permissionRequest(
                requestId: "preview-perm",
                toolName: "Bash",
                toolInputJSON: """
                {"command":"rm -rf /tmp/some-nonexistent-test-dir-xyz","description":"Attempt rm -rf to trigger permission prompt"}
                """,
                pattern: nil
            ))
        case .exitPlan:
            let plan = """
            **Demo Plan: AskUserQuestion + ExitPlanMode**

            ## Context
            User wants a demo of the plan-mode permission/question flow: making a plan, asking clarifying questions via AskUserQuestion, then requesting approval via ExitPlanMode with allowedPrompts permission requests.

            ## Approach
            1. Ask a couple of clarifying questions with AskUserQuestion (demonstrating single-select, multiSelect, and a preview option).
            2. Finalize this plan file.
            3. Call ExitPlanMode with allowedPrompts entries so the user sees the Bash permission-request UI.

            **Requested permissions:**
            - Bash: run ./scripts/reload.sh --tag <tag> for tagged macOS cmux dev builds
            """
            return (.exitPlan, .exitPlan(
                requestId: "preview-plan",
                plan: plan,
                defaultMode: .manual
            ))
        case .question:
            return (.question, .question(
                requestId: "preview-question",
                questions: [
                    WorkstreamQuestionPrompt(
                        id: "q0",
                        header: "Demo task",
                        prompt: "What flavor of demo plan should I write so we can show off the permission-prompt UX?",
                        multiSelect: false,
                        options: [
                            .init(
                                id: "shell",
                                label: "Tiny shell script",
                                description: "A throwaway bash script in /Users/lawrence/fun that prints a greeting — minimal, quick to approve."
                            ),
                            .init(
                                id: "node",
                                label: "Node CLI tool",
                                description: "A small Node.js CLI that fetches a URL — exercises install + network permissions."
                            ),
                            .init(
                                id: "python",
                                label: "Python data script",
                                description: "A Python script that reads a CSV and prints stats — exercises pip + file read permissions."
                            ),
                        ]
                    ),
                    WorkstreamQuestionPrompt(
                        id: "q1",
                        prompt: "Which permission prompts should I include in ExitPlanMode?",
                        multiSelect: true,
                        options: [
                            .init(id: "reload", label: "reload.sh tagged build"),
                            .init(id: "gh_pr", label: "gh PR read"),
                            .init(id: "git_read", label: "git read"),
                            .init(id: "gh_wf", label: "gh workflow run"),
                        ]
                    ),
                ]
            ))
        case .todos:
            return (.todos, .todos([
                .init(id: "t1", content: "PR 4: Mac becomes thin daemon client", state: .inProgress),
                .init(id: "t2", content: "PR 8: Keystroke-latency performance gate in CI", state: .pending),
                .init(id: "t3", content: "PR 1: Daemon sqlite persistence skeleton", state: .completed),
                .init(id: "t4", content: "PR 2: Incremental mutation RPCs + diff broadcaster", state: .completed),
                .init(id: "t5", content: "PR 3: Relay WebSocket framing", state: .completed),
                .init(id: "t6", content: "PR 5: iOS side of the wire", state: .completed),
                .init(id: "t7", content: "PR 6: Reconnect + resume", state: .completed),
                .init(id: "t8", content: "PR 7: Crash reporting", state: .completed),
            ]))
        case .toolUse:
            return (.toolUse, .toolUse(
                toolName: "Bash",
                toolInputJSON: "node \"/Users/lawrence/.claude/plugins/cache/openai…\""
            ))
        case .userPrompt:
            return (.userPrompt, .userPrompt(
                text: "reproduced bad again. ugh why is this so hard /…"
            ))
        }
    }

    private static func sampleDecision(for kind: Kind) -> WorkstreamDecision {
        switch kind {
        case .permission: return .permission(.once)
        case .exitPlan: return .exitPlan(.autoAccept)
        case .question: return .question(selections: ["Tiny shell script"])
        default: return .permission(.once)
        }
    }

    private static func titleHint(for kind: Kind) -> String? {
        switch kind {
        case .permission: return "Write"
        case .exitPlan: return "ExitPlanMode"
        case .question: return "AskUserQuestion"
        default: return nil
        }
    }
}
#endif
