import AppKit
import CmuxHomeCore
import CmuxNextActions
import CmuxNextChiefMemory
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextHomeEngine
import CmuxNextPages
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
        context.services.pages.register(WebPageTab(.importHistory, symbol: "square.and.arrow.down", title: ChiefMemoryImportStrings.title,
            view: { [weak services = context.services] key in
                guard let services else { return nil }
                return Self.importHistoryPage(for: key, services: services)
            }))
        registry.bindEffect(actionID, effect: { invocation in
            do {
                let target = try resolveTarget(invocation["chief"]?.stringValue, context: context)
                let named = invocation["source"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
                if named == nil, case .local = target {
                    guard context.services.pages.show(.importHistory, in: context.services.windows.active, focus: invocation.allowsViewChange) != nil else {
                        return .refused(RefusalStrings.noWindowOpen)
                    }
                    return .done
                }
                guard let tool = bundledTool() else { return .refused(ChiefMemoryImportStrings.noTool) }
                let interactive = !registry.isCapturingRefusal
                let window = CloudHandlers.window(context)
                let detectArgs = Self.detectArguments(muxHome: muxHome(context), invocation: invocation)
                // action-wait-allow: a named import or Cloud picker waits for the CLI; the local GUI opens synchronously above
                return .waiting(.externalProcess) {
                    let runner = Self.runner(tool: tool, target: target, context: context, window: window)
                    if let named {
                        await runner.importSources([named])
                        return nil
                    }
                    guard interactive else { return ActionWorkFailure(ChiefMemoryImportStrings.nothingFound) }
                    let found = await runner.detect(detectArgs)
                    runner.askWhichSources(found)
                    return nil
                }
            } catch { return .refused(String(describing: error)) }
        })
        registry.bindEffect(undoActionID, effect: { invocation in
            do {
                guard let tool = bundledTool() else { return .refused(ChiefMemoryImportStrings.noTool) }
                let target = try resolveTarget(invocation["chief"]?.stringValue, context: context)
                let window = CloudHandlers.window(context)
                // action-wait-allow: restoring the CLI's backup has no optimistic stand-in
                return .waiting(.externalProcess) {
                    await Self.runner(tool: tool, target: target, context: context, window: window).undo()
                    return nil
                }
            } catch { return .refused(String(describing: error)) }
        })
    }

    /// The page is a regular WebPageTab: its existing lifecycle closes the router and bridge.
    private static func importHistoryPage(for key: String, services: AppServices) -> PageWebView? {
        let home = HomeBrainHost.muxHome(tag: services.environment.tag).path
        let provider = ImportHistoryPageProvider(muxHome: home, personOnlyMessage: RefusalStrings.personOnlyFromPage) { arguments, timeout in
            guard let tool = bundledTool() else { throw PageError(code: "cmux.importHistory.no_tool", message: ChiefMemoryImportStrings.noTool) }
            let output = await run(tool, arguments, timeout: timeout)
            guard output.status == 0 else { throw PageError(code: "cmux.importHistory.failed", message: output.message) }
            return try CmuxNextSettings.JSONValue.parse(Data(output.stdout.utf8))
        }
        provider.restart = { [weak services] in _ = services?.home.brain.ensure(asked: true) }
        let native = AppPageNativeProvider(services: services, page: .importHistory)
        let routes = [PageRoute(prefix: "cmux.importHistory.", provider: provider), PageRoute(prefix: "cmux.app.", provider: native)]
        guard let page = PageWebView(descriptor: .importHistory, routes: routes) else { return nil }
        provider.anchor = { [weak page] in page?.window }
        native.anchor = { [weak page] in page }
        provider.finish = { [weak services, weak page] _ in
            guard let services else { return }
            services.onboarding.historyImportFinished()
            if let nativeWindow = page?.window,
               let window = services.windows.controllers.first(where: { $0.window === nativeWindow }), window.shownTopPage == .page(.importHistory) {
                window.leaveTopPage()
                window.topPages.close(.page(.importHistory))
            } else if let pane = services.paneController(showingTab: key), let tab = services.pages.stripID(showing: key, in: pane) {
                pane.close([tab])
            }
        }
        return page
    }

    /// `Contents/Resources/bin/optchat-chief`, or nil when this build does not carry it (as ``BundledAgentMemoryIndex``).
    nonisolated static func bundledTool(bundle: Bundle = .main) -> URL? {
        guard let url = bundle.resourceURL?.appendingPathComponent("bin/optchat-chief"),
              FileManager.checked.isExecutableFile(atPath: url.path) else { return nil }
        return url
    }

    /// What the first-run panel offers, read off the main thread (none without the tool): run at launch unasked, so never ~/Downloads (LAUNCH-NO-TCC-PROMPTS).
    static func detectForOffer(muxHome: String) async -> [MemorySource] {
        guard let tool = bundledTool() else { return [] }
        let output = await run(tool, offerDetectArguments(muxHome: muxHome), timeout: .seconds(60))
        return MemorySource.parse(Data(output.stdout.utf8))
    }

    /// The offer's detect: unasked, so never the export zips in ~/Downloads and ~/Desktop (LAUNCH-NO-TCC-PROMPTS).
    static func offerDetectArguments(muxHome: String) -> [String] { MemoryImportCommand(target: .local(muxHome: muxHome)).detect() }

    /// A run's detect: only the person's own (``ActionInvocation/isPersonsOwnRun``) lists the export zips in the
    /// guarded ~/Downloads and ~/Desktop; automation names a zip instead (`source: zip:/path`) (LAUNCH-NO-TCC-PROMPTS).
    static func detectArguments(muxHome: String, invocation: ActionInvocation) -> [String] { MemoryImportCommand(target: .local(muxHome: muxHome)).detect(exports: invocation.isPersonsOwnRun) }

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

    /// Binds the shared importer to this app's destination and process lifetime.
    private static func runner(tool: URL, target: Destination, context: AppActionContext, window: NSWindow?) -> MemoryImportFlow {
        let isLocal: Bool = if case .local = target { true } else { false }
        return MemoryImportFlow(isLocal: isLocal, window: window, toastID: toastID,
            run: { await run(tool, $0, timeout: $1) }, prepare: {
                switch target {
                case .local(let home):
                    return MemoryImportFlow.Session(command: MemoryImportCommand(target: .local(muxHome: home)))
                case .cloud(let chief):
                    let (folder, file) = try await ChiefMoveHandlers.writeToken(context.services.cloud)
                    return MemoryImportFlow.Session(command: MemoryImportCommand(target: .cloud(chief: chief, tokenFile: file.path)),
                                                    cleanup: { discard(folder) })
                }
            }, restart: { _ = context.services.home.brain.ensure(asked: true) }, onUndo: {
                var arguments: [String: ActionValue] = [:]
                if case .cloud(let chief) = target { arguments["chief"] = .string(chief) }
                _ = context.registry.perform(undoActionID, invocation: ActionInvocation(arguments: arguments, origin: .user))
            })
    }

    /// Deletes the Cloud token's folder, off the main thread.
    nonisolated static func discard(_ folder: URL) {
        // task-owner: one small delete; ends with it
        Task.detached(priority: .utility) { try? FileManager.checked.removeItem(at: folder) }
    }

    typealias Output = MemoryImportFlow.Output

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

extension PageDescriptor {
    static let importHistory = PageDescriptor(
        id: "cmux.import-history", resource: "import-history", namespaces: ["cmux.importHistory."],
        nativeOps: [PageNativeOp.clipboardWrite])
}

extension InternalPageID {
    static let importHistory = InternalPageID(rawValue: "import-history")
}
