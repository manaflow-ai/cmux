#if DEBUG
public import AppKit

/// DEBUG proofs of Update Everything's surfaces with a fixed plan (`debug.update_everything`): a
/// capture slot has no remote machines and no outdated agent CLIs, so the real action would only
/// say everything is up to date. Nothing here updates anything.
@MainActor
public struct UpdateEverythingPreview {
    public init() {}

    /// This Mac with an app update and an agent CLI, an SSH machine and a Cloud machine on another
    /// daemon build, and a paired server whose agent CLI is outdated.
    public static var plan: UpdateEverythingPlan { UpdateEverythingPlan(machines: [
        UpdateEverythingMachine(id: "local", name: UpdateEverythingMachine.thisMac, kind: .local,
                                app: UpdateEverythingChange(name: "cmux NEXT", from: "1.0.0-nightly.3932981", to: "1.0.0-nightly.3933104"),
                                harnesses: [UpdateEverythingChange(id: "claude", name: "Claude Code", from: "2.0.1", to: "2.0.5")],
                                runningThreads: 1),
        UpdateEverythingMachine(id: "ssh:devbox", name: "devbox", kind: .ssh,
                                daemon: UpdateEverythingChange(name: UpdateEverythingMachine.daemonName, from: "4c1d2e9", to: "9a7f3b0"),
                                harnesses: [UpdateEverythingChange(id: "codex", name: "Codex", from: "0.40.0", to: "0.42.0")],
                                runningThreads: 2),
        UpdateEverythingMachine(id: "cloud:build", name: "build-runner", kind: .cloud,
                                daemon: UpdateEverythingChange(name: UpdateEverythingMachine.daemonName, from: "4c1d2e9", to: "9a7f3b0")),
        UpdateEverythingMachine(id: "server:brain", name: "team-brain", kind: .server,
                                harnesses: [UpdateEverythingChange(id: "codex", name: "Codex", from: "0.40.0", to: "0.42.0")]),
    ]) }

    /// Opens the confirmation for ``plan`` in `window`; its answer is dropped.
    public static func confirm(in window: NSWindow) {
        // task-owner: one DEBUG confirmation; ends when the person answers or the window closes
        Task { @MainActor in _ = await UpdateEverythingDaemon.confirm(plan, in: window) }
    }

    /// Shows the run's progress toast in `window`.
    public static func progress(in window: NSWindow) {
        UpdateEverythingDaemon.toast(UpdateEverythingRunner.updating, duration: .seconds(60), in: window)
    }
}
#endif
