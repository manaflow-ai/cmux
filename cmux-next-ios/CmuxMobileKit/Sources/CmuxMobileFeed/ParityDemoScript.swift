#if DEBUG && os(iOS)
import CmuxMobileAgentChat
import CmuxMobileDesign
import Foundation

/// DEBUG-only demo driver (`-CmuxMobileDemo acp-parity`, phases with
/// `-CmuxMobileDemoPhases swipe,artifacts,subagents,checkpoints,handoff`): Feed swipe
/// actions (reveal, Done with undo, Allow, Answer), then in the Claude chat
/// the artifacts browser (filters, grid, HTML with Source, image, video, PDF,
/// link), subagents (list, a subagent, a nested one), checkpoints (restore
/// with confirmation) and the handoff (pick, review, attest, start). Each
/// command runs through the screen's own state; pauses pace the recording.
@MainActor
public struct ParityDemoScript {
    let director = DemoDirector.shared

    public init() {}

    public func run() async {
        let arguments = ProcessInfo.processInfo.arguments
        var phases = ["swipe", "artifacts", "subagents", "checkpoints", "handoff"]
        if let index = arguments.firstIndex(of: "-CmuxMobileDemoPhases"), arguments.indices.contains(index + 1) {
            phases = arguments[index + 1].split(separator: ",").map(String.init)
        }
        await pause(2.0)
        if phases.contains("swipe") { await swipe() }
        await post(.feedOpen(event: "f-finished"), then: 2.0)
        if phases.contains("artifacts") { await artifacts() }
        if phases.contains("subagents") { await subagents() }
        if phases.contains("checkpoints") { await checkpoints() }
        if phases.contains("handoff") { await handoff() }
        mark("end")
    }

    private func pause(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }

    private func post(_ command: DemoDirector.Command, then seconds: Double) async {
        director.post(command)
        await pause(seconds)
    }

    /// Phase marks for frame review (`log stream` or the simulator's unified log).
    private func mark(_ phase: String) {
        print("cmux-mobile-demo phase \(phase) at \(Date().timeIntervalSince1970)")
    }

    private func swipe() async {
        mark("swipe")
        await post(.feedScroll(toEvent: "f-pricing"), then: 1.6)
        await post(.feedSwipe(event: "f-pricing", edge: "trailing"), then: 1.6)
        await post(.feedSwipeAction(event: "f-pricing", action: "done"), then: 2.4)
        await post(.feedSwipe(event: "f-permission", edge: "trailing"), then: 1.6)
        await post(.feedSwipeAction(event: "f-permission", action: "allow"), then: 2.0)
        await post(.feedScrollTop, then: 1.4)
        await post(.feedSwipe(event: "f-question", edge: "trailing"), then: 1.6)
        await post(.feedSwipeClose, then: 1.0)
        await post(.feedScroll(toEvent: "f-math"), then: 1.4)
        await post(.feedSwipe(event: "f-math", edge: "trailing"), then: 1.4)
        await post(.feedSwipeAction(event: "f-math", action: "read"), then: 1.4)
    }

    private func artifacts() async {
        mark("artifacts")
        await post(.chatOpenArtifacts, then: 2.2)
        await post(.artifactsOpen("cmux-next-ios/verify/transport-report.html"), then: 2.4)
        await post(.artifactsSource(true), then: 2.0)
        await post(.artifactsSource(false), then: 1.0)
        await post(.artifactsBack, then: 1.2)
        await post(.artifactsFilter("Images"), then: 1.4)
        await post(.artifactsLayout(grid: true), then: 2.0)
        await post(.artifactsOpen("cmux-next-ios/verify/screenshots/terminal.png"), then: 2.0)
        await post(.artifactsBack, then: 1.0)
        await post(.artifactsLayout(grid: false), then: 1.0)
        await post(.artifactsFilter("All"), then: 1.0)
        await post(.artifactsOpen("cmux-next-ios/verify/recordings/demo.mp4"), then: 3.0)
        await post(.artifactsBack, then: 1.0)
        await post(.artifactsOpen("cmux-next-ios/verify/transport-report.pdf"), then: 2.4)
        await post(.artifactsBack, then: 1.0)
        await post(.artifactsOpen("cmux-next-ios/rust/cmux-mobile-link/src/dial.rs"), then: 2.2)
        await post(.artifactsBack, then: 1.0)
        await post(.artifactsClose, then: 1.4)
    }

    private func subagents() async {
        mark("subagents")
        await post(.chatScroll(toTop: true), then: 2.4)
        await post(.chatOpenParity("subagents"), then: 2.2)
        await post(.parityClose, then: 1.2)
        await post(.chatOpenParity("WireGuard dialer"), then: 2.6)
        await post(.parityClose, then: 1.2)
    }

    private func checkpoints() async {
        mark("checkpoints")
        await post(.chatOpenParity("checkpoints"), then: 2.0)
        await post(.checkpointRestore(id: "cp-h2"), then: 2.0)
        await post(.checkpointConfirm, then: 4.5)
        await post(.parityClose, then: 1.2)
    }

    private func handoff() async {
        mark("handoff")
        await post(.chatOpenParity("handoff"), then: 2.0)
        await post(.handoffPick(id: "codex"), then: 2.6)
        await post(.handoffFill(reference: "git stash@{0}"), then: 1.6)
        await post(.handoffStart, then: 3.0)
        await post(.parityClose, then: 1.2)
    }
}
#endif
