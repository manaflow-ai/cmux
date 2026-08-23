#if os(iOS)
import CmuxMobileSupport

/// One rendered line of the welcome demo transcript.
struct WelcomeDemoLine: Equatable, Identifiable {
    /// How a transcript line is styled, mirroring a real cmux session.
    enum Style: Equatable {
        /// A command the user typed, rendered behind a prompt glyph.
        case command
        /// A status line spoken by the agent.
        case agent
        /// Plain tool output.
        case output
        /// The completion line, rendered in the success tint.
        case success
        /// The reply the person chose, echoed like typed input.
        case reply
    }

    /// Stable identity for insertion animations.
    let id: Int
    let style: Style
    let text: String
}

/// One tappable answer to the demo agent's question.
struct WelcomeDemoReply: Equatable, Identifiable {
    /// Stable identity for chip rendering and accessibility.
    let id: Int
    /// The chip label.
    let title: String
    /// The line echoed into the transcript when chosen.
    let echo: String
    /// The lines the agent plays after this choice.
    let resolution: [WelcomeDemoLine]
}

/// The question the demo agent pauses on, with its reply choices.
struct WelcomeDemoQuestion: Equatable {
    /// The question line appended to the transcript when the pause begins.
    let prompt: WelcomeDemoLine
    /// The tappable choices; every choice resolves the demo.
    let replies: [WelcomeDemoReply]
}

/// One step of demo playback.
enum WelcomeDemoStep: Equatable {
    /// Reveal a transcript line.
    case line(WelcomeDemoLine)
    /// Pause on the agent's question until the person answers.
    case question(WelcomeDemoQuestion)
}

/// The scripted interactive session played on the tour's first stage.
///
/// The script demonstrates the product's core loop by making the person
/// perform it: an agent works, pauses on a question, and the person's tapped
/// reply unblocks it. Content is deterministic so package tests and UI tests
/// can assert exact transcripts.
struct WelcomeDemoScript: Equatable {
    /// The playback steps in order. Exactly one step is a question.
    let steps: [WelcomeDemoStep]

    /// Creates a script from explicit steps (tests compose small fixtures).
    /// - Parameter steps: The playback steps in order.
    init(steps: [WelcomeDemoStep]) {
        self.steps = steps
    }

    /// Creates the standard first-run script.
    init() {
        self.init(steps: [
            .line(WelcomeDemoLine(
                id: 0,
                style: .command,
                text: L10n.string(
                    "mobile.welcome.demo.command",
                    defaultValue: "cmux run \"fix the flaky auth test\""
                )
            )),
            .line(WelcomeDemoLine(
                id: 1,
                style: .agent,
                text: L10n.string(
                    "mobile.welcome.demo.pickedUp",
                    defaultValue: "Agent picked up the task"
                )
            )),
            .line(WelcomeDemoLine(
                id: 2,
                style: .output,
                text: L10n.string(
                    "mobile.welcome.demo.reading",
                    defaultValue: "reading tests/auth.spec.ts"
                )
            )),
            .line(WelcomeDemoLine(
                id: 3,
                style: .output,
                text: L10n.string(
                    "mobile.welcome.demo.foundRace",
                    defaultValue: "found a race: token refresh vs. mock clock"
                )
            )),
            .question(WelcomeDemoQuestion(
                prompt: WelcomeDemoLine(
                    id: 4,
                    style: .agent,
                    text: L10n.string(
                        "mobile.welcome.demo.question",
                        defaultValue: "Replace the mock clock with a fake timer?"
                    )
                ),
                replies: [
                    WelcomeDemoReply(
                        id: 0,
                        title: L10n.string(
                            "mobile.welcome.demo.replyYes",
                            defaultValue: "Yes, replace it"
                        ),
                        echo: L10n.string(
                            "mobile.welcome.demo.replyYesEcho",
                            defaultValue: "yes, replace it"
                        ),
                        resolution: [
                            WelcomeDemoLine(
                                id: 5,
                                style: .output,
                                text: L10n.string(
                                    "mobile.welcome.demo.replacing",
                                    defaultValue: "swapping mock clock for fake timers"
                                )
                            ),
                            WelcomeDemoLine(
                                id: 6,
                                style: .success,
                                text: L10n.string(
                                    "mobile.welcome.demo.done",
                                    defaultValue: "2 files changed · tests green"
                                )
                            ),
                        ]
                    ),
                    WelcomeDemoReply(
                        id: 1,
                        title: L10n.string(
                            "mobile.welcome.demo.replyDiff",
                            defaultValue: "Show the diff first"
                        ),
                        echo: L10n.string(
                            "mobile.welcome.demo.replyDiffEcho",
                            defaultValue: "show the diff first"
                        ),
                        resolution: [
                            WelcomeDemoLine(
                                id: 5,
                                style: .output,
                                text: L10n.string(
                                    "mobile.welcome.demo.diff",
                                    defaultValue: "+ vi.useFakeTimers()  − MockClock()"
                                )
                            ),
                            WelcomeDemoLine(
                                id: 6,
                                style: .success,
                                text: L10n.string(
                                    "mobile.welcome.demo.done",
                                    defaultValue: "2 files changed · tests green"
                                )
                            ),
                        ]
                    ),
                ]
            )),
        ])
    }
}
#endif
