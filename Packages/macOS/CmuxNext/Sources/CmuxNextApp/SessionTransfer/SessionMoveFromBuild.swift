import AppKit
import CmuxNextActions
import CmuxNextDesign
import CmuxNextSessionTransfer

/// Move Sessions from Another cmux Build… (cx-yxmkh): finds the sibling
/// builds with sessions, asks which to move in a cmux dialog (and again,
/// with no Return default, before ending a terminal there), pulls them
/// here through `SessionTransferService` and says what happened in a toast.
/// The picker and the toast text are `SessionMoveSelection` and `SessionMoveOutcome`.
@MainActor
struct SessionMoveFromBuild {
    let transfer: SessionTransferService

    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let services = context.services
        registry.bind("session.moveFromBuild", run: { _ in
            let window = services.windows.active?.window ?? NSApp.keyWindow ?? NSApp.mainWindow
            registry.track(Task { @MainActor in
                await SessionMoveFromBuild(transfer: services.sessionTransfer).run(in: window)
            })
        })
    }

    func run(in window: NSWindow?) async -> ActionWorkFailure? {
        let peers: [SessionTransferPeer]
        do {
            peers = try await transfer.discover()
        } catch {
            Self.toast(SessionTransferService.message(for: error), in: window)
            return ActionWorkFailure("move-sessions: \(error)")
        }
        let selection = SessionMoveSelection(peers: peers)
        guard !selection.isEmpty else {
            Self.toast(SessionMoveOutcome.none, in: window)
            return nil
        }
        // With no window there is nobody to ask, so nothing moves. Discovery takes seconds, so the
        // window it started in may have closed meanwhile; a closed window's dialog would never answer.
        guard let window = window.flatMap({ $0.isVisible ? $0 : nil }) ?? NSApp.keyWindow ?? NSApp.mainWindow else { return nil }
        let answer = await CmuxDialogCenter.shared.present(selection.dialog, in: .window(window))
        let pulls = selection.pulls(answer)
        guard !pulls.isEmpty else { return nil }
        // Moving a terminal ends its program and scrollback in the other build: that takes a
        // second, explicit Move and End Terminals (no Return default), never the picker's Return.
        let terminals = selection.terminals(in: pulls)
        if !terminals.isEmpty {
            let confirm = await CmuxDialogCenter.shared.present(SessionMoveSelection.endTerminalsDialog(for: terminals), in: .window(window))
            guard SessionMoveSelection.confirmsEndingTerminals(confirm) else { return nil }
        }
        var outcome = SessionMoveOutcome()
        for pull in pulls {
            do {
                outcome.record(try await transfer.pull(source: pull.source, ids: pull.ids, idleTerminalsOnly: true), titles: selection.titles(in: pull.source))
            } catch {
                outcome.record(failure: SessionTransferService.message(for: error), from: pull.heading)
            }
        }
        Self.toast(outcome.notice, in: window)
        return nil
    }

    static func toast(_ message: String, in window: NSWindow?) {
        guard let window = window ?? NSApp.keyWindow ?? NSApp.mainWindow else { return }
        _ = CmuxToastCenter.shared.show(CmuxToast(id: "sessionMove", message: message), in: window)
    }
}
