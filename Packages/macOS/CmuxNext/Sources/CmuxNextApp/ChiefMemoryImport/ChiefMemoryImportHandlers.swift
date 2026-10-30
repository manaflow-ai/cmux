import AppKit
import CmuxHomeCore
import CmuxNextActions
import CmuxNextChiefMemory
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextHomeEngine
import CmuxNextSettings
import Foundation
import UniformTypeIdentifiers

/// "Import Memories…" (plans/cmux-next/chief-memory-import-DESIGN.md): finds what this Mac already holds from
/// other tools (Claude Code, Codex, ChatGPT and claude.ai exports), lets the person pick, then runs the bundled
/// `optchat-chief memory import-from` in the background: a dry run for the cost, then the write. The Chief keeps
/// answering; a local write stops the host for a moment (one writer) and the next message starts it again. The
/// result is a toast with Undo. `chief.importMemories.undo` takes the last import back.
///
/// Arguments of `chief.importMemories`: `chief` (a Cloud Chief's id: import into it instead of this Mac's Chief),
/// `source` (a source name such as `claude-code` or `zip:/path`: skips the dialog, for automation).
@MainActor
enum ChiefMemoryImportHandlers {
    static let actionID: ActionID = "chief.importMemories"
    static let undoActionID: ActionID = "chief.importMemories.undo"
    static let toastID = "chief-memory-import"

    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        // action-wait-allow: starts a process and a dialog that wait on the person and on another process; nothing local can stand in
        registry.bind(actionID, run: { invocation in
            guard let tool = bundledTool() else { throw ActionWorkFailure(ChiefMemoryImportStrings.noTool) }
            let target = try resolveTarget(invocation["chief"]?.stringValue, context: context)
            let named = invocation["source"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            let interactive = !registry.isCapturingRefusal
            let window = CloudHandlers.window(context)
            // task-owner: one detect, one dialog and one background import the person started; ends with the result toast
            registry.track(Task { @MainActor in
                let runner = Runner(tool: tool, target: target, context: context, window: window)
                if let named {
                    await runner.importSources([named])
                    return nil
                }
                guard interactive else { return ActionWorkFailure(ChiefMemoryImportStrings.nothingFound) }
                let found = await runner.detect()
                runner.askWhichSources(found)
                return nil
            })
        })
        // action-wait-allow: runs a process and waits for it; nothing local can stand in
        registry.bind(undoActionID, run: { invocation in
            guard let tool = bundledTool() else { throw ActionWorkFailure(ChiefMemoryImportStrings.noTool) }
            let target = try resolveTarget(invocation["chief"]?.stringValue, context: context)
            let window = CloudHandlers.window(context)
            // task-owner: one undo the person started; ends with the result toast
            registry.track(Task { @MainActor in
                await Runner(tool: tool, target: target, context: context, window: window).undo()
                return nil
            })
        })
    }

    /// `Contents/Resources/bin/optchat-chief`, or nil when this build does not carry it (as ``BundledAgentMemoryIndex``).
    nonisolated static func bundledTool(bundle: Bundle = .main) -> URL? {
        guard let url = bundle.resourceURL?.appendingPathComponent("bin/optchat-chief"),
              FileManager.checked.isExecutableFile(atPath: url.path) else { return nil }
        return url
    }

    /// What the first-run panel offers: the sources found on this Mac, read off the main thread (none in a build without the tool).
    static func detectForOffer(muxHome: String) async -> [MemorySource] {
        guard let tool = bundledTool() else { return [] }
        let output = await run(tool, MemoryImportCommand(target: .local(muxHome: muxHome)).detect(), timeout: .seconds(60))
        return MemorySource.parse(Data(output.stdout.utf8))
    }

    private static func muxHome(_ context: AppActionContext) -> String {
        HomeBrainHost.muxHome(tag: context.services.environment.tag).path
    }

    private enum Destination {
        case local(muxHome: String)
        case cloud(chief: String)
    }

    private static func resolveTarget(_ chief: String?, context: AppActionContext) throws -> Destination {
        guard let chief, !chief.isEmpty else { return .local(muxHome: muxHome(context)) }
        // Only a Cloud Chief the directory lists is a cloud target; any other id is this Mac's default Chief.
        if context.services.home.directory.chief(for: ParticipantID(chief)) != nil {
            guard context.services.cloud.isSignedIn else { throw ActionWorkFailure(ChiefMemoryImportStrings.signInFirst) }
            return .cloud(chief: chief)
        }
        return .local(muxHome: muxHome(context))
    }

    /// One import or undo, off the main thread but for its dialog and toasts.
    @MainActor
    private struct Runner {
        let tool: URL
        let target: Destination
        let context: AppActionContext
        let window: NSWindow?

        private var isLocal: Bool { if case .local = target { true } else { false } }

        private func command(tokenFile: String?) -> MemoryImportCommand {
            switch target {
            case .local(let home): MemoryImportCommand(target: .local(muxHome: home))
            case .cloud(let chief): MemoryImportCommand(target: .cloud(chief: chief, tokenFile: tokenFile ?? ""))
            }
        }

        func detect() async -> [MemorySource] {
            let arguments = MemoryImportCommand(target: .local(muxHome: ChiefMemoryImportHandlers.muxHome(context))).detect()
            let output = await ChiefMemoryImportHandlers.run(tool, arguments, timeout: .seconds(60))
            return MemorySource.parse(Data(output.stdout.utf8))
        }

        func askWhichSources(_ found: [MemorySource]) {
            guard let window = window ?? NSApp.keyWindow ?? NSApp.mainWindow else { return }
            var lines = [found.isEmpty ? ChiefMemoryImportStrings.nothingFound : ChiefMemoryImportStrings.lead]
            if !found.isEmpty { lines.append(ChiefMemoryImportStrings.safety) }
            if isLocal, !found.isEmpty { lines.append(ChiefMemoryImportStrings.restartNote) }
            // Every source starts checked; the person unchecks what stays out.
            let fields = found.enumerated().map { CmuxDialogField.check(id: String($0.offset), title: $0.element.title, on: true) }
            var buttons: [CmuxDialogButton] = [.cancel(), CmuxDialogButton(id: "file", title: ChiefMemoryImportStrings.chooseFile)]
            if !found.isEmpty { buttons.append(CmuxDialogButton(id: "import", title: ChiefMemoryImportStrings.importButton, role: .default)) }
            let spec = CmuxDialogSpec(title: ChiefMemoryImportStrings.title, lines: lines, fields: fields, buttons: buttons,
                                      identifier: "cmux.dialog.chief.importMemories")
            let runner = self
            CmuxDialogCenter.shared.present(spec, in: .window(window)) { answer in
                switch answer.button {
                case "import":
                    let picked = found.enumerated().filter { answer.isOn(String($0.offset)) }.map(\.element.source)
                    guard !picked.isEmpty else { return }
                    // task-owner: the background import the person started; ends with its result toast
                    Task { @MainActor in await runner.importSources(picked) }
                case "file":
                    guard let path = runner.chooseZip() else { return }
                    // task-owner: the background import of the chosen file; ends with its result toast
                    Task { @MainActor in await runner.importSources(["zip:" + path]) }
                default:
                    return
                }
            }
        }

        private func chooseZip() -> String? {
            let panel = NSOpenPanel()
            panel.message = ChiefMemoryImportStrings.choosePrompt
            panel.allowedContentTypes = [.zip]
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            return panel.runModal() == .OK ? panel.url?.path : nil
        }

        /// A dry run per source for the cost and the count, then the write, one source after the other.
        func importSources(_ sources: [String]) async {
            toast(ChiefMemoryImportStrings.working, duration: .seconds(600))
            var tokenDir: URL?
            defer { if let tokenDir { ChiefMemoryImportHandlers.discard(tokenDir) } }
            var tokenFile: String?
            if case .cloud = target {
                do {
                    let (dir, file) = try await ChiefMoveHandlers.writeToken(context.services.cloud)
                    (tokenDir, tokenFile) = (dir, file.path)
                } catch {
                    return stop(ChiefMemoryImportStrings.failed + ": " + String(describing: error))
                }
            }
            let command = command(tokenFile: tokenFile)
            let batch = "b" + String(Int(Date().timeIntervalSince1970 * 1000))
            var written = 0
            for source in sources {
                let plan = await ChiefMemoryImportHandlers.run(tool, command.dryRun(source), timeout: .seconds(600))
                guard plan.status == 0, let report = MemoryImportReport.parse(Data(plan.stdout.utf8)) else {
                    return stop(ChiefMemoryImportStrings.failed + ": " + plan.message)
                }
                if report.plan.new == 0 { continue }
                if report.estCostUSD > Double(MemoryImportCommand.maxCostUSD) {
                    return stop(ChiefMemoryImportStrings.tooCostly(String(format: "%.0f", report.estCostUSD)))
                }
                let wrote = await ChiefMemoryImportHandlers.run(tool, command.write(source, batch: batch), timeout: .seconds(3600))
                guard wrote.status == 0, let done = MemoryImportReport.parse(Data(wrote.stdout.utf8)) else {
                    if isLocal { _ = context.services.home.brain.ensure(asked: true) }
                    return stop(ChiefMemoryImportStrings.failed + ": " + wrote.message)
                }
                written += done.written ?? 0
            }
            // The host was stopped for the write; the next message would start it, and so does this.
            if isLocal { _ = context.services.home.brain.ensure(asked: true) }
            guard written > 0 else { return stop(ChiefMemoryImportStrings.nothingNew) }
            let handle = toast(ChiefMemoryImportStrings.done(written), action: .undo(ChiefMemoryImportStrings.undo), duration: .seconds(30))
            let registry = context.registry
            var arguments: [String: ActionValue] = [:]
            if case .cloud(let chief) = target { arguments["chief"] = .string(chief) }
            let invocation = ActionInvocation(arguments: arguments, origin: .user)
            handle?.onAction = { _ = registry.perform(ChiefMemoryImportHandlers.undoActionID, invocation: invocation) }
        }

        func undo() async {
            var tokenDir: URL?
            defer { if let tokenDir { ChiefMemoryImportHandlers.discard(tokenDir) } }
            var tokenFile: String?
            if case .cloud = target {
                do {
                    let (dir, file) = try await ChiefMoveHandlers.writeToken(context.services.cloud)
                    (tokenDir, tokenFile) = (dir, file.path)
                } catch {
                    return stop(ChiefMemoryImportStrings.failed + ": " + String(describing: error))
                }
            }
            let output = await ChiefMemoryImportHandlers.run(tool, command(tokenFile: tokenFile).undo(), timeout: .seconds(300))
            if isLocal { _ = context.services.home.brain.ensure(asked: true) }
            if output.status == 0 { toast(ChiefMemoryImportStrings.undone) }
            else if output.message.contains("nothing to undo") { toast(ChiefMemoryImportStrings.nothingToUndo) }
            else { toast(ChiefMemoryImportStrings.failed + ": " + output.message) }
        }

        /// Shows `message` and ends the import or undo that called it.
        private func stop(_ message: String) { toast(message) }

        @discardableResult
        private func toast(_ message: String, action: CmuxToast.Action? = nil, duration: Duration = .seconds(8)) -> CmuxToastHandle? {
            guard let window = window ?? NSApp.keyWindow ?? NSApp.mainWindow else { return nil }
            return CmuxToastCenter.shared.show(CmuxToast(id: ChiefMemoryImportHandlers.toastID, message: message, action: action, duration: duration),
                                               in: window)
        }
    }

    /// Deletes the Cloud token's folder, off the main thread.
    nonisolated static func discard(_ folder: URL) {
        // task-owner: one small delete; ends with it
        Task.detached(priority: .utility) { try? FileManager.checked.removeItem(at: folder) }
    }

    struct Output: Sendable {
        var status: Int32
        var stdout: String
        /// stderr, else stdout: what to show when the CLI fails.
        var message: String
    }

    /// Runs the tool off the main actor (a transcript conversion can take seconds).
    static func run(_ tool: URL, _ arguments: [String], timeout: Duration) async -> Output {
        do {
            let result = try await ProcessRunner.run(executable: tool, arguments: arguments, environment: nil,
                                                     timeout: timeout, clock: ContinuousClock())
            let out = String(decoding: result.stdout, as: UTF8.self)
            let err = String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return Output(status: result.status, stdout: out, message: err.isEmpty ? out.trimmingCharacters(in: .whitespacesAndNewlines) : err)
        } catch {
            return Output(status: -1, stdout: "", message: String(describing: error))
        }
    }
}
