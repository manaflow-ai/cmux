import Foundation

/// The Realtime session a Chief call opens with: model, voice, Chief's
/// persona and briefing, turn detection, input transcription and the tools.
/// Sent as the `session` part of `POST /v1/realtime/calls`.
public struct VoiceCallSessionConfig: Sendable, Equatable {
    public var model: String
    public var voice: String
    public var instructions: String
    /// Input transcription for the captions. `gpt-live-transcribe` (July
    /// 2026) is the newest streaming model; ``fallbackTranscriptionModel``
    /// is used when a session refuses it.
    public var transcriptionModel: String
    public var tools: [VoiceCallTool]

    public static let preferredTranscriptionModel = "gpt-live-transcribe"
    public static let fallbackTranscriptionModel = "gpt-4o-mini-transcribe"

    public init(model: String, voice: String, instructions: String,
                transcriptionModel: String = VoiceCallSessionConfig.preferredTranscriptionModel,
                tools: [VoiceCallTool] = VoiceCallTool.all) {
        self.model = model
        self.voice = voice
        self.instructions = instructions
        self.transcriptionModel = transcriptionModel
        self.tools = tools
    }

    /// The session object (GA shape: `type: realtime`).
    public var json: Data {
        let session: [String: Any] = [
            "type": "realtime",
            "model": model,
            "instructions": instructions,
            "output_modalities": ["audio"],
            "audio": [
                "input": [
                    "transcription": ["model": transcriptionModel],
                    // Semantic VAD waits for the user to finish a thought;
                    // speaking over Chief interrupts it (barge-in).
                    "turn_detection": ["type": "semantic_vad", "create_response": true, "interrupt_response": true],
                    "noise_reduction": ["type": "near_field"],
                ] as [String: Any],
                "output": ["voice": voice],
            ],
            "tools": tools.map(\.json),
            "tool_choice": "auto",
        ]
        return (try? JSONSerialization.data(withJSONObject: session, options: [.sortedKeys])) ?? Data()
    }
}

/// What Chief's voice knows when the call starts.
public struct VoiceCallBriefing: Sendable, Equatable {
    /// Chief's name ("Chief" unless renamed on the Mac).
    public var chiefName: String
    /// The user's first name, when known.
    public var userName: String?
    /// Where Chief runs and whether it's reachable, in one line.
    public var chiefStatus: String
    /// The newest Chief conversation lines, oldest first ("You: …", "Chief: …").
    public var recentMessages: [String]
    /// One line per workspace.
    public var workspaces: [String]
    /// One line per agent waiting on the user.
    public var attention: [String]

    public init(chiefName: String, userName: String? = nil, chiefStatus: String, recentMessages: [String] = [],
                workspaces: [String] = [], attention: [String] = []) {
        self.chiefName = chiefName
        self.userName = userName
        self.chiefStatus = chiefStatus
        self.recentMessages = recentMessages
        self.workspaces = workspaces
        self.attention = attention
    }

    /// The session instructions: Chief's persona, how to use the tools, the briefing.
    public func instructions(now: Date) -> String {
        let user = userName.map { "The user's name is \($0)." } ?? ""
        let day = now.formatted(.dateTime.weekday(.wide).month(.wide).day().hour().minute())
        var text = """
        You are \(chiefName), the user's chief of staff in cmux. cmux runs the user's coding agents \
        (Claude Code, Codex and others) in workspaces on their Macs. You are on a live voice call from \
        the user's iPhone. \(user) It is \(day).

        How to talk:
        - Speak like a sharp, warm colleague on the phone: short sentences, one idea at a time, no lists \
        read aloud, no markdown, no code. Say numbers and names naturally.
        - Keep answers brief unless asked for detail. If the user interrupts, stop and listen.
        - Never invent workspace names, agents or results. Use your tools to look things up.

        How to act:
        - Real work (code changes, running tests, opening pull requests, starting or steering agents) is \
        done by \(chiefName)'s agent on the Mac. Hand it over with send_to_chief: one clear, self-contained \
        instruction written as the user would type it. Confirm in a few words what you sent.
        - When the request is ambiguous or risky (deleting, pushing, spending money), ask one short \
        question before sending.
        - Replies from the agent arrive as system messages starting with "Chief replied:". Summarize them \
        for the ear in a sentence or two, and offer detail.
        - Use list_workspaces, list_needs_attention and read_chief_messages to answer questions about what \
        is going on. You cannot approve permissions or answer agents' questions yourself; tell the user \
        which agent is waiting and offer to pass a message to Chief.
        - When the user says goodbye or is done, say a short goodbye, then call end_call.

        \(chiefName) status: \(chiefStatus)
        """
        if !recentMessages.isEmpty {
            text += "\n\nRecent messages in the Chief chat (oldest first):\n" + recentMessages.joined(separator: "\n")
        }
        if !workspaces.isEmpty {
            text += "\n\nWorkspaces:\n" + workspaces.joined(separator: "\n")
        }
        if !attention.isEmpty {
            text += "\n\nWaiting on the user:\n" + attention.joined(separator: "\n")
        }
        return text
    }
}
