public import AppKit
public import CmuxNextDesign
public import Foundation
import UniformTypeIdentifiers

/// The existing native import chooser and named-source flow, shared by the App's thin bindings.
/// The App supplies its destination, process runner and token lifetime; no App state lives here.
@MainActor
public struct MemoryImportFlow {
    public nonisolated struct Output: Sendable {
        public var status: Int32
        public var stdout: String
        public var message: String
        public init(status: Int32, stdout: String, message: String) {
            self.status = status
            self.stdout = stdout
            self.message = message
        }
    }

    public struct Session {
        public var command: MemoryImportCommand
        public var cleanup: () -> Void
        public init(command: MemoryImportCommand, cleanup: @escaping () -> Void = {}) {
            self.command = command
            self.cleanup = cleanup
        }
    }

    private let isLocal: Bool
    private let window: NSWindow?
    private let toastID: String
    private let run: @MainActor ([String], Duration) async -> Output
    private let prepare: @MainActor () async throws -> Session
    private let restart: @MainActor () -> Void
    private let onUndo: @MainActor () -> Void

    public init(isLocal: Bool, window: NSWindow?, toastID: String,
                run: @escaping @MainActor ([String], Duration) async -> Output,
                prepare: @escaping @MainActor () async throws -> Session,
                restart: @escaping @MainActor () -> Void, onUndo: @escaping @MainActor () -> Void) {
        self.isLocal = isLocal
        self.window = window
        self.toastID = toastID
        self.run = run
        self.prepare = prepare
        self.restart = restart
        self.onUndo = onUndo
    }

    public func detect(_ arguments: [String]) async -> [MemorySource] {
        let output = await run(arguments, .seconds(60))
        return MemorySource.parse(Data(output.stdout.utf8))
    }

    public func askWhichSources(_ found: [MemorySource]) {
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
                // task-owner: the chosen file's panel and import; ends with its result toast
                Task { @MainActor in
                    guard let path = await runner.chooseZip() else { return }
                    await runner.importSources(["zip:" + path])
                }
            default:
                return
            }
        }
    }

    private func chooseZip() async -> String? {
        let panel = NSOpenPanel()
        panel.message = ChiefMemoryImportStrings.choosePrompt
        panel.allowedContentTypes = [.zip]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        let response = await withCheckedContinuation { done in
            if let window = window ?? NSApp.keyWindow ?? NSApp.mainWindow {
                panel.beginSheetModal(for: window) { done.resume(returning: $0) }
            } else { panel.begin { done.resume(returning: $0) } }
        }
        return response == .OK ? panel.url?.path : nil
    }

    /// A dry run per source for the cost and the count, then the write, one source after the other.
    public func importSources(_ sources: [String]) async {
        toast(ChiefMemoryImportStrings.working, duration: .seconds(600))
        let session: Session
        do { session = try await prepare() }
        catch { return stop(ChiefMemoryImportStrings.failed + ": " + String(describing: error)) }
        defer { session.cleanup() }
        let command = session.command
        let batch = "b" + String(Int(Date().timeIntervalSince1970 * 1000))
        var written = 0
        for source in sources {
            let plan = await run(command.dryRun(source), .seconds(600))
            guard plan.status == 0, let report = MemoryImportReport.parse(Data(plan.stdout.utf8)) else {
                return stop(ChiefMemoryImportStrings.failed + ": " + plan.message)
            }
            if report.plan.new == 0 { continue }
            if report.estCostUSD > Double(MemoryImportCommand.maxCostUSD) {
                return stop(ChiefMemoryImportStrings.tooCostly(String(format: "%.0f", report.estCostUSD)))
            }
            let wrote = await run(command.write(source, batch: batch), .seconds(3600))
            guard wrote.status == 0, let done = MemoryImportReport.parse(Data(wrote.stdout.utf8)) else {
                if isLocal { restart() }
                return stop(ChiefMemoryImportStrings.failed + ": " + wrote.message)
            }
            written += done.written ?? 0
        }
        // The host was stopped for the write; the next message would start it, and so does this.
        if isLocal { restart() }
        guard written > 0 else { return stop(ChiefMemoryImportStrings.nothingNew) }
        let handle = toast(ChiefMemoryImportStrings.done(written), action: .undo(ChiefMemoryImportStrings.undo), duration: .seconds(30))
        handle?.onAction = { onUndo() }
    }

    public func undo() async {
        let session: Session
        do { session = try await prepare() }
        catch { return stop(ChiefMemoryImportStrings.failed + ": " + String(describing: error)) }
        defer { session.cleanup() }
        let output = await run(session.command.undo(), .seconds(300))
        if isLocal { restart() }
        if output.status == 0 { toast(ChiefMemoryImportStrings.undone) }
        else if output.message.contains("nothing to undo") { toast(ChiefMemoryImportStrings.nothingToUndo) }
        else { toast(ChiefMemoryImportStrings.failed + ": " + output.message) }
    }

    /// Shows `message` and ends the import or undo that called it.
    private func stop(_ message: String) { toast(message) }

    @discardableResult
    private func toast(_ message: String, action: CmuxToast.Action? = nil, duration: Duration = .seconds(8)) -> CmuxToastHandle? {
        guard let window = window ?? NSApp.keyWindow ?? NSApp.mainWindow else { return nil }
        return CmuxToastCenter.shared.show(CmuxToast(id: toastID, message: message, action: action, duration: duration),
                                           in: window)
    }
}
