// DEBUG and Demo builds only: mock content is never compiled into Production.
#if DEBUG
import CmuxAgentQuestion
import Foundation

/// The agent chat's row gallery (`-cmux-mobile-demo row-gallery`, part from
/// `CMUX_MOBILE_ROW_GALLERY`): one replayed history per part that draws every transcript row kind
/// (`ChatRow.Kind`) and its variants, each turn's prompt naming the row it shows, so a capture can
/// page through all of them. Parts that need a running last turn (a pending permission, a question,
/// the working line, the sudo card, a streaming answer) are their own part, because only a chat's
/// last turn can be running.
extension MockAgentSession {
    /// Every part, in capture order.
    public static let rowGalleryParts = [
        "prompts", "answers", "tools", "edits", "cards", "endings", "earlier",
        "live-permission", "live-question", "live-working", "live-retrying", "live-elevation", "live-streaming",
    ]

    func replayRowGallery(_ part: String) {
        let base = Date().addingTimeInterval(-3 * 3600)
        var clock = 0.0
        func at() -> Date {
            clock += 90
            return base.addingTimeInterval(clock)
        }
        switch part {
        case "prompts": galleryPrompts(at)
        case "answers": galleryAnswers(at)
        case "tools": galleryTools(at)
        case "edits": galleryEdits(at)
        case "cards": galleryCards(at)
        case "endings": galleryEndings(at)
        case "earlier":
            emit(.earlierHistory(true))
            finishedTurn("g-earlier", "Row: session line when the chat opened on its newest history (\"Showing messages since …\")",
                         at: at()) { id in
                self.emit(.update(.agentMessageChunk(text: "Older turns are still on the Mac; scrolling up reads them.", messageId: "\(id)-m")))
            }
        case "live-permission": galleryLivePermission(at)
        case "live-question": galleryLiveQuestion(at)
        case "live-working": galleryLiveWorking(at, retrying: false)
        case "live-retrying": galleryLiveWorking(at, retrying: true)
        case "live-elevation": galleryLiveElevation(at)
        case "live-streaming": galleryLiveStreaming(at)
        default:
            finishedTurn("g-unknown", "Unknown row gallery part \"\(part)\"", at: at()) { id in
                self.emit(.update(.agentMessageChunk(text: "Parts: " + Self.rowGalleryParts.joined(separator: ", "), messageId: "\(id)-m")))
            }
        }
    }

    // MARK: Building blocks

    /// A turn that opens with `prompt`, runs `body`, and ends with `status`.
    private func finishedTurn(_ id: String, _ prompt: String, at: Date, attachments: [AgentAttachment] = [],
                              status: AgentTurn.Status = .completed, errorText: String? = nil, body: (String) -> Void) {
        emit(.userMessage(text: prompt, promptId: "p-\(id)", turnId: id, attachments: attachments, at: at))
        emit(.turnStarted(turnId: id, at: at))
        body(id)
        emit(.turnResult(turnId: id, status: status, errorText: errorText, at: at.addingTimeInterval(37)))
    }

    /// A turn left running (the chat's last).
    private func runningTurn(_ id: String, _ prompt: String, at: Date, body: (String) -> Void) {
        emit(.userMessage(text: prompt, promptId: "p-\(id)", turnId: id, attachments: [], at: at))
        emit(.turnStarted(turnId: id, at: at))
        body(id)
    }

    private func say(_ text: String, _ id: String) {
        emit(.update(.agentMessageChunk(text: text, messageId: id)))
    }

    private func call(_ id: String, _ title: String, _ kind: ACPToolCall.Kind, _ status: ACPToolCall.Status = .completed,
                      output: String? = nil, path: String? = nil, command: String? = nil, exit: Int? = nil) {
        emit(.update(.toolCall(ACPToolCall(
            id: id, title: title, kind: kind, status: status,
            content: output.map { [.content(.text($0))] } ?? [],
            locations: path.map { [.init(path: $0)] } ?? [],
            rawInput: command.map { .object(["command": .string($0)]) },
            rawOutput: exit.map { .object(["exit_code": .number(Double($0))]) }
        ))))
    }

    // MARK: Prompts

    private func galleryPrompts(_ at: () -> Date) {
        finishedTurn("g-prompt", "Row: prompt bubble (plain text)", at: at()) { id in
            say("Answer under a plain prompt.", "\(id)-m")
        }
        finishedTurn("g-prompt-long", "Row: prompt bubble (long text). " + String(repeating: "The transport layer needs a switch between WebRTC and WireGuard that the person can flip per Mac, and the dialer has to honor it on the next connection without a relaunch. ", count: 3),
                     at: at()) { id in
            say("Answer under a long prompt.", "\(id)-m")
        }
        finishedTurn("g-prompt-att", "Row: prompt bubble with an image and a file attached", at: at(), attachments: [
            AgentAttachment(id: "g-att-img", kind: .image, name: "connection-settings.png", data: MockScript.attachmentPNG),
            AgentAttachment(id: "g-att-file", kind: .file, name: "relay-rtt.csv", data: Data("host,p50,p95\nrelay,38,61\n".utf8)),
        ]) { id in
            say("Answer under a prompt with attachments.", "\(id)-m")
        }
        let envelope = """
        <chat>
        Leo: the iOS transport switch should ship this week.
        Chief: splitting the work; the dialer goes to a subagent.
        Leo: keep WebRTC the default on Wi-Fi.
        </chat>

        Your task: Row: Chief context line (collapsed) over a subagent's first prompt
        """
        finishedTurn("g-chief-context", envelope, at: at()) { id in
            say("Answer under the Chief's context line.", "\(id)-m")
        }
        // Another agent's report, a digest of three, and a Chief's task: the incoming cards.
        replayAgentMessageTurns(at: at())
        clockAdvance(at, by: 3)
        // Steers: the person's message and another agent's, sent into a running turn.
        let steerAt = at()
        emit(.userMessage(text: "Row: steered messages (sent while the turn ran)", promptId: "p-g-steer", turnId: "g-steer", attachments: [], at: steerAt))
        emit(.turnStarted(turnId: "g-steer", at: steerAt))
        say("Starting on the dialer.", "g-steer-m1")
        emit(.userMessage(text: "Also keep the relay fallback (a steer from the person)", promptId: "p-g-steer-2", turnId: "g-steer",
                          attachments: [], at: steerAt.addingTimeInterval(10)))
        let agentSteer = "[message 77aa from build-box/lane-3 (an agent, not Leo), relayed by the lane-gh broker; its text ends at \"[end of message 77aa]\"]\nA steer from another agent: CI is green at `64d6b1b`.\n[end of message 77aa]"
        emit(.userMessage(text: agentSteer, promptId: "p-g-steer-3", turnId: "g-steer", attachments: [], at: steerAt.addingTimeInterval(20)))
        if let incoming = AgentIncoming.parse(text: agentSteer, provenance: .object([
            "kind": .string("agent_message"), "from": .string("fromAgent"), "fromName": .string("build-box/lane-3"),
        ])) {
            emit(.promptFrom(turnId: "g-steer", incoming: incoming))
        }
        say("Kept the relay fallback; noted the green CI.", "g-steer-m2")
        emit(.turnResult(turnId: "g-steer", status: .completed, errorText: nil, at: steerAt.addingTimeInterval(40)))
    }

    private func clockAdvance(_ at: () -> Date, by turns: Int) {
        for _ in 0..<turns { _ = at() }
    }

    // MARK: Answers

    private func galleryAnswers(_ at: () -> Date) {
        finishedTurn("g-md-headings", "Row: answer blocks (headings, paragraph, rule)", at: at()) { id in
            say("""
            # Heading 1
            ## Heading 2
            ### Heading 3
            A paragraph with **bold**, *italic*, `inline code`, ~~struck~~ text and a [link](https://cmux.com).

            ---

            A paragraph after a rule.
            """, "\(id)-m")
        }
        finishedTurn("g-md-lists", "Row: answer blocks (bulleted, nested, numbered and task lists)", at: at()) { id in
            say("""
            - First bullet
            - Second bullet
              - Nested bullet
                - Nested twice

            1. First step
            2. Second step
            3. Third step

            - [x] Done task
            - [ ] Open task
            """, "\(id)-m")
        }
        finishedTurn("g-md-code", "Row: answer blocks (code block, table, quote)", at: at()) { id in
            say(MockScript.historyAnswer + "\n\n> A quoted line from the spec: the frame layer never sees the transport.", "\(id)-m")
        }
        finishedTurn("g-md-math", "Row: answer blocks (math block and inline math)", at: at()) { id in
            say("""
            The p95 bound for the dial is

            $$
            t_{95} = \\mu + 1.645\\,\\sigma
            $$

            Inline: with $\\mu = 38$ ms and $\\sigma = 14$ ms the bound is about $61$ ms.
            """, "\(id)-m")
        }
        finishedTurn("g-thought", "Row: thought (finished, collapsed)", at: at()) { id in
            emit(.update(.agentThoughtChunk(text: MockScript.thinking)))
            say("Answer after a thought.", "\(id)-m")
        }
        finishedTurn("g-md-long", "Row: long answer (many blocks)", at: at()) { id in
            say((1...6).map { "### Section \($0)\nParagraph \($0) explains one part of the transport change in a few sentences so the answer runs past one screen." }
                .joined(separator: "\n\n"), "\(id)-m")
        }
    }

    // MARK: Tools

    private func galleryTools(_ at: () -> Date) {
        let link = "cmux-next-ios/rust/cmux-mobile-link/src/"
        let kinds: [(ACPToolCall.Kind, String, String?, String?, String?)] = [
            (.read, "Read dial.rs", MockScript.readSnippet, "\(link)dial.rs", nil),
            (.search, "Search TransportKind", MockScript.searchOutput, nil, nil),
            (.execute, "git status", " M Sources/Transport/LinkDialer.swift\n?? docs/dialer-notes.md", nil, "git status --short"),
            (.fetch, "Fetch https://datatracker.ietf.org/doc/html/rfc8445", "Interactive Connectivity Establishment (ICE) …", nil, nil),
            (.think, "Think", "Weighing WebRTC against WireGuard for cellular.", nil, nil),
            (.delete, "Delete old-dialer.rs", nil, "\(link)old-dialer.rs", nil),
            (.move, "Move dial.rs → dialer.rs", nil, "\(link)dialer.rs", nil),
            (.switchMode, "Switch mode to Plan", nil, nil, nil),
            (.other, "mcp__github__get_pull_request", "#36125 · open · 3 checks green", nil, nil),
        ]
        for (index, (kind, title, output, path, command)) in kinds.enumerated() {
            finishedTurn("g-tool-\(index)", "Row: tool (\(kind.rawValue), completed)", at: at()) { id in
                call("\(id)-c", title, kind, output: output, path: path, command: command, exit: kind == .execute ? 0 : nil)
            }
        }
        finishedTurn("g-tool-fail", "Row: tool (execute, failed with exit 101)", at: at(), status: .completed) { id in
            call("\(id)-c", "cargo test -p cmux-mobile-link", .execute, .failed,
                 output: "error[E0425]: cannot find value `ice_timeout` in this scope\n --> src/webrtc.rs:41:9\n\nerror: could not compile `cmux-mobile-link`",
                 command: "cargo test -p cmux-mobile-link", exit: 101)
            say("The Rust build failed; fixing the missing binding next.", "\(id)-m")
        }
        finishedTurn("g-tool-group", "Row: tool group (reads, a search and a command, folded)", at: at()) { id in
            for (n, file) in ["lib.rs", "dial.rs", "frame.rs"].enumerated() {
                call("\(id)-r\(n)", "Read \(file)", .read, output: "// \(file)\n" + MockScript.readSnippet, path: "\(link)\(file)")
            }
            call("\(id)-s", "Search ice_timeout", .search, output: "\(link)webrtc.rs:41: let ice_timeout = Duration::from_secs(8);")
            call("\(id)-x", "swift test --filter Link", .execute, output: MockScript.swiftTestOutput, command: "swift test --filter Link", exit: 0)
            say("Read the dialer, found the timeout, tests pass.", "\(id)-m")
        }
        let whoAt = at()
        emit(.userMessage(text: "Row: who-else card (other sessions on these files)", promptId: "p-g-who", turnId: "g-who", attachments: [], at: whoAt))
        emit(.turnStarted(turnId: "g-who", at: whoAt))
        replayWhoElseCall()
        say("Two other sessions touch frame.rs; coordinating before the edit.", "g-who-m")
        emit(.turnResult(turnId: "g-who", status: .completed, errorText: nil, at: whoAt.addingTimeInterval(20)))
        // Subagents (and their artifacts) as one turn.
        replaySubagentTurn(at: at())
    }

    // MARK: Edits and plans

    private func galleryEdits(_ at: () -> Date) {
        let S = MockScript.self
        finishedTurn("g-edit-new", "Row: edit (new file) and the edited-files card", at: at()) { id in
            emit(.update(.toolCall(ACPToolCall(id: "\(id)-e", title: "Write TransportKind.swift", kind: .edit, status: .completed,
                                               content: [.diff(path: S.kindPath, oldText: nil, newText: S.kindNew)],
                                               locations: [.init(path: S.kindPath)]))))
        }
        finishedTurn("g-edit-mod", "Row: edit (changed lines)", at: at()) { id in
            emit(.update(.toolCall(ACPToolCall(id: "\(id)-e", title: "Edit LinkDialer.swift", kind: .edit, status: .completed,
                                               content: [.diff(path: S.dialerPath, oldText: S.dialerOld, newText: S.dialerNew)],
                                               locations: [.init(path: S.dialerPath)]))))
            say("Routed the dialer through the selected transport.", "\(id)-m")
        }
        finishedTurn("g-edit-multi", "Row: edit (two files in one call)", at: at()) { id in
            emit(.update(.toolCall(ACPToolCall(id: "\(id)-e", title: "Apply patch", kind: .edit, status: .completed, content: [
                .diff(path: S.settingsPath, oldText: S.settingsOld, newText: S.settingsNew(cellular: "webrtc")),
                .diff(path: "cmux-next-ios/PROTOCOL.md", oldText: "Transport: WebRTC.\n", newText: "Transport: WebRTC or WireGuard, per Mac.\n"),
            ]))))
        }
        finishedTurn("g-edit-delete", "Row: edit (file emptied)", at: at()) { id in
            emit(.update(.toolCall(ACPToolCall(id: "\(id)-e", title: "Edit OldDialer.swift", kind: .edit, status: .completed,
                                               content: [.diff(path: "Sources/OldDialer.swift", oldText: "struct OldDialer {}\n// unused\n", newText: "")]))))
        }
        finishedTurn("g-edit-failed", "Row: edit (failed)", at: at()) { id in
            emit(.update(.toolCall(ACPToolCall(id: "\(id)-e", title: "Edit Missing.swift", kind: .edit, status: .failed,
                                               content: [.content(.text("File not found: Sources/Missing.swift"))],
                                               locations: [.init(path: "Sources/Missing.swift")]))))
            say("That file does not exist; skipping it.", "\(id)-m")
        }
        finishedTurn("g-plan", "Row: plan (completed, in progress and pending steps)", at: at()) { id in
            var plan = S.plan
            plan[0].status = .completed
            plan[1].status = .completed
            plan[2].status = .inProgress
            emit(.update(.plan(plan)))
            say("Two steps done; the tests are running.", "\(id)-m")
        }
        finishedTurn("g-plan-done", "Row: plan (all steps done)", at: at()) { id in
            emit(.update(.plan(S.plan.map { var entry = $0; entry.status = .completed; return entry })))
        }
    }

    // MARK: Cards

    private func galleryCards(_ at: () -> Date) {
        for (index, (option, label)) in [("allow", "allowed"), ("always", "always allowed"), ("deny", "denied")].enumerated() {
            finishedTurn("g-perm-\(index)", "Row: permission card (\(label))", at: at()) { id in
                let tool = ACPToolCall(id: "\(id)-x", title: "cargo test -p cmux-mobile-link", kind: .execute, status: .pending,
                                       rawInput: .object(["command": .string("cargo test -p cmux-mobile-link -- --nocapture")]))
                emit(.update(.toolCall(tool)))
                emit(.permissionRequest(ACPPermissionRequest(id: "\(id)-p", toolCall: tool, options: [
                    ACPPermissionOption(id: "allow", name: "Allow once", kind: .allowOnce),
                    ACPPermissionOption(id: "always", name: "Always allow cargo test in this workspace", kind: .allowAlways),
                    ACPPermissionOption(id: "deny", name: "Deny", kind: .rejectOnce),
                ], cwd: "~/Development/cmux")))
                emit(.permissionDecision(permissionId: "\(id)-p", optionId: option))
                let allowed = option != "deny"
                emit(.update(.toolCallUpdate(ACPToolCallUpdate(toolCallId: "\(id)-x", status: allowed ? .completed : .failed,
                                                               content: [.content(.text(allowed ? MockScript.cargoOutput : "Denied by the person."))]))))
            }
        }
        finishedTurn("g-question", "Row: question card (answered)", at: at()) { id in
            let question = MockScript.question(session: summary.id, id: "\(id)-q")
            emit(.question(question))
            emit(.questionAnswered(questionId: question.id, answer: AgentQuestionAnswer(selections: [
                "default": .init(optionIDs: ["wireguard"]), "surfaces": .init(optionIDs: ["connection", "per-mac"]),
            ])))
            say("WireGuard on cellular, with the switch in Settings and per Mac.", "\(id)-m")
        }
        finishedTurn("g-next-options", "Row: next-step card with listed answers (answered by the next prompt)", at: at()) { id in
            say("""
            The switch is wired and both suites pass.

            [outward] Should I open the PR now or wait for the phone recording?
            - Open the PR now
            - Wait for the recording
            """, "\(id)-m")
        }
        finishedTurn("g-next-yesno", "Open the PR now", at: at()) { id in
            say("""
            Opened #36125.

            [irreversible] Should I merge it once CI is green?
            """, "\(id)-m")
        }
        finishedTurn("g-wrapup", "Yes", at: at()) { id in
            say("Merged after CI went green.", "\(id)-m")
            emit(.update(.toolCall(ACPToolCall(
                id: "\(id)-w", title: "mcp__acpmux__wrap_up", kind: .other, status: .completed,
                rawInput: .object([
                    "recap": .string("The transport switch landed in #36125; WireGuard is the cellular default."),
                    "ask": .string("Want a TestFlight build for the phones?"),
                    "actions": .array([.string("Build TestFlight"), .string("Not yet")]),
                    "try": .object(["label": .string("Open the PR"), "url": .string("https://github.com/manaflow-ai/cmux/pull/36125")]),
                    "verify": .array([.string("Settings → Connection shows the picker"), .string("A cellular dial uses WireGuard")]),
                    "report": .string("cmux-next-ios/verify/transport-report.html"),
                ])
            ))))
        }
    }

    // MARK: Endings

    private func galleryEndings(_ at: () -> Date) {
        finishedTurn("g-done", "Row: finished turn with its action row (copy, retry, more)", at: at()) { id in
            say("A finished answer; the row under it copies, retries or opens more.", "\(id)-m")
        }
        finishedTurn("g-stopped", "Row: stopped turn (the person pressed Stop)", at: at(), status: .cancelled) { id in
            call("\(id)-x", "swift test", .execute, .failed, output: "Test Suite 'All tests' started…", command: "swift test")
        }
        finishedTurn("g-failed-text", "Row: failed turn with the agent's error", at: at(), status: .failed,
                     errorText: "API Error: 529 Overloaded. The model is busy; try again in a moment.") { _ in }
        finishedTurn("g-failed-bare", "Row: failed turn without an error text", at: at(), status: .failed) { _ in }
        emit(.promptNotSent(text: "Row: prompt not sent (the composer got this draft back)", attachments: [], promptID: "p-g-unsent",
                            reason: "Your Mac is offline. The message was not sent."))
    }

    // MARK: Live (the last turn runs)

    private func galleryLivePermission(_ at: () -> Date) {
        finishedTurn("g-before", "An earlier finished turn", at: at()) { id in say("Earlier answer.", "\(id)-m") }
        runningTurn("g-live-perm", "Row: running turn waiting on a permission (live thought, running tools, plan in progress, permission card)",
                    at: at()) { id in
            emit(.update(.agentThoughtChunk(text: MockScript.thinking)))
            var plan = MockScript.plan
            plan[0].status = .completed
            plan[1].status = .inProgress
            emit(.update(.plan(plan)))
            call("\(id)-r1", "Read lib.rs", .read, output: MockScript.readSnippet, path: "cmux-next-ios/rust/cmux-mobile-link/src/lib.rs")
            call("\(id)-r2", "Read dial.rs", .read, .inProgress, path: "cmux-next-ios/rust/cmux-mobile-link/src/dial.rs")
            let tool = ACPToolCall(id: "\(id)-x", title: "cargo test -p cmux-mobile-link", kind: .execute, status: .pending,
                                   rawInput: .object(["command": .string("cargo test -p cmux-mobile-link -- --nocapture")]))
            emit(.update(.toolCall(tool)))
            emit(.permissionRequest(ACPPermissionRequest(id: "\(id)-p", toolCall: tool, options: [
                ACPPermissionOption(id: "allow", name: "Allow once", kind: .allowOnce),
                ACPPermissionOption(id: "always", name: "Always allow cargo test in this workspace", kind: .allowAlways),
                ACPPermissionOption(id: "deny", name: "Deny", kind: .rejectOnce),
            ], cwd: "~/Development/cmux")))
        }
    }

    private func galleryLiveQuestion(_ at: () -> Date) {
        finishedTurn("g-before", "An earlier finished turn", at: at()) { id in say("Earlier answer.", "\(id)-m") }
        runningTurn("g-live-q", "Row: running turn asking a question (two items, one multi-select)", at: at()) { id in
            say(MockScript.beforeQuestion, "\(id)-m")
            emit(.question(MockScript.question(session: summary.id, id: "\(id)-q")))
        }
    }

    private func galleryLiveWorking(_ at: () -> Date, retrying: Bool) {
        finishedTurn("g-before", "An earlier finished turn", at: at()) { id in say("Earlier answer.", "\(id)-m") }
        let start = Date().addingTimeInterval(-75)
        let prompt = retrying ? "Row: running turn retrying its model request (attempt 2 of 10)"
            : "Row: running turn with the working line, and two prompts queued behind it"
        emit(.userMessage(text: prompt, promptId: "p-g-live-w", turnId: "g-live-w", attachments: [], at: start))
        emit(.turnStarted(turnId: "g-live-w", at: start))
        call("g-live-w-x", "swift test --filter Link", .execute, .inProgress, command: "swift test --filter Link")
        if retrying {
            emit(.retrying(attempt: 2, maxAttempts: 10, status: 529))
        } else {
            emit(.queued(text: "Then update PROTOCOL.md", promptId: "p-g-q1", position: 1))
            emit(.queued(text: "And record the switch on a phone", promptId: "p-g-q2", position: 2))
        }
    }

    private func galleryLiveElevation(_ at: () -> Date) {
        finishedTurn("g-before", "An earlier finished turn", at: at()) { id in say("Earlier answer.", "\(id)-m") }
        runningTurn("g-live-sudo", "Row: running turn asking to run a command as root (sudo card)", at: at()) { id in
            say("Installing the WireGuard kernel tools needs root on the Mac.", "\(id)-m")
            emit(.elevationRequest(AgentElevationAsk(id: "\(id)-el", argv: ["brew", "install", "wireguard-tools"],
                                                     reason: "Install the WireGuard tools the link tests need",
                                                     host: summary.macName, timeoutSecs: 120, nonce: "gallery", instance: "gallery")))
        }
    }

    private func galleryLiveStreaming(_ at: () -> Date) {
        finishedTurn("g-before", "An earlier finished turn", at: at()) { id in say("Earlier answer.", "\(id)-m") }
        runningTurn("g-live-stream", "Row: running turn streaming (a running edit, then an answer with an open code block)", at: at()) { id in
            emit(.update(.toolCall(ACPToolCall(id: "\(id)-e", title: "Edit LinkDialer.swift", kind: .edit, status: .inProgress,
                                               locations: [.init(path: MockScript.dialerPath)]))))
            say("Here is the new dialer so far:\n\n```swift\npub async fn dial(config: &DialConfig) -> Result<Link> {\n    match config.transport {\n        TransportKind::WebRtc =>", "\(id)-m")
        }
    }
}
#endif
