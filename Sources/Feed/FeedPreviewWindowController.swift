#if DEBUG
import AppKit
import CMUXWorkstream
import SwiftUI

/// Debug-only window that renders every Feed item kind + state against
/// synthetic fixtures. Open via Debug → Debug Windows → Feed Preview…
final class FeedPreviewWindowController: NSWindowController, NSWindowDelegate {
    static let shared = FeedPreviewWindowController()

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 820),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Feed Preview"
        window.identifier = NSUserInterfaceItemIdentifier("cmux.feedPreview")
        window.minSize = NSSize(width: 420, height: 500)
        window.center()
        window.isReleasedWhenClosed = false
        self.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: FeedPreviewRootView())
    }

    func show() {
        if window?.isVisible != true {
            window?.center()
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct FeedPreviewRootView: View {
    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(FeedPreviewFixtures.Kind.allCases) { kind in
                        section(for: kind)
                    }
                }
                .padding(12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Text("Feed Preview · all kinds + states")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
            Spacer()
            Button("Inject all into Feed") {
                injectAllIntoLiveStore()
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private func section(for kind: FeedPreviewFixtures.Kind) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(kind.label.uppercased())
                    .font(.system(size: 11, weight: .heavy))
                    .tracking(0.8)
                    .foregroundColor(.primary.opacity(0.9))
                Rectangle()
                    .fill(Color.primary.opacity(0.10))
                    .frame(height: 1)
            }
            ForEach(FeedPreviewFixtures.allStates(for: kind), id: \.id) { item in
                VStack(alignment: .leading, spacing: 4) {
                    stateCaption(for: item)
                    FeedPreviewCardHost(item: item)
                }
            }
        }
    }

    @ViewBuilder
    private func stateCaption(for item: WorkstreamItem) -> some View {
        let (label, color): (String, Color) = {
            switch item.status {
            case .pending: return ("Pending", .orange)
            case .resolved: return ("Resolved", .green)
            case .expired: return ("Expired", .secondary)
            case .telemetry: return ("Telemetry", .blue)
            }
        }()
        Text(label.uppercased())
            .font(.system(size: 9, weight: .bold))
            .tracking(0.6)
            .foregroundColor(color)
    }

    private func injectAllIntoLiveStore() {
        Task { @MainActor in
            guard let store = FeedCoordinator.shared.store else { return }
            for kind in FeedPreviewFixtures.Kind.allCases {
                for item in FeedPreviewFixtures.allStates(for: kind) {
                    store.ingest(FeedPreviewFixtures.wireEvent(for: item))
                }
            }
        }
    }
}

/// Re-uses the real `FeedPanelView` row by wrapping the rendered row
/// view at its nearest public entry point. We expose just enough API
/// by constructing a `FeedItemSnapshot` + bound action closures.
private struct FeedPreviewCardHost: View {
    let item: WorkstreamItem

    var body: some View {
        FeedItemRow(
            snapshot: FeedItemSnapshot(
                item: item,
                userPromptEcho: "make a plan and ask me for permissions requests…"
            ),
            actions: FeedPreviewActions.make(),
            isSelected: false,
            onPressSelect: {},
            onControlFocus: {},
            onControlBlur: {},
            onActivate: {}
        )
    }
}

/// Closure bundle that logs actions to the console instead of hitting
/// the live coordinator. Useful for testing the preview in isolation.
private enum FeedPreviewActions {
    static func make() -> FeedRowActions {
        FeedRowActions(
            approvePermission: { id, mode in print("preview.permission \(id) \(mode)") },
            replyQuestion: { id, selections in print("preview.question \(id) \(selections)") },
            approveExitPlan: { id, mode, feedback in
                print("preview.exitPlan \(id) \(mode) feedback=\(feedback ?? "nil")")
            },
            jump: { ws in print("preview.jump \(ws)") },
            sendText: { ws, text in print("preview.sendText \(ws) \(text)") }
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
