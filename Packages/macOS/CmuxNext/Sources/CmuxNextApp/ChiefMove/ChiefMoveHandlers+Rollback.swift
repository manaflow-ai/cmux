import AppKit
import CmuxNextActions
import CmuxNextHomeEngine
import Foundation

/// Roll Back Chief Move (`chief.moveRollback`) and the Teleport menu's wiring: the menu's picks run
/// `chief.moveTo` and `chief.moveRollback`, the same actions as Cmd-Shift-P, never a second path.
extension ChiefMoveHandlers {
    static let rollbackID: ActionID = "chief.moveRollback"

    /// Binds Roll Back: the chip shows "Rolling back…" on the input's turn, then the bundled
    /// `cmux chief move rollback` runs on the app's Chief home (after a confirmation when a person
    /// asked), and the chip reads the home again.
    static func bindRollback(into registry: ActionRegistry, context: AppActionContext) {
        let bundled = context.services.bundledCLI
        let teleport = context.services.chiefTeleport
        registry.bindEffect(rollbackID, unavailable: {
            if bundled.known == nil { return ChiefMoveStrings.noCLI }
            if teleport.location == .thisMac { return ChiefMoveStrings.notMoved }
            return teleport.phase.isRunning ? ChiefMoveStrings.running : nil
        }, effect: { _ in
            guard let cli = bundled.known else { return .refused(ChiefMoveStrings.noCLI) }
            guard teleport.location != .thisMac else { return .refused(ChiefMoveStrings.notMoved) }
            guard !teleport.phase.isRunning else { return .refused(ChiefMoveStrings.running) }
            let interactive = !registry.isCapturingRefusal
            let window = CloudHandlers.window(context)
            let cloud = context.services.cloud
            let fromCloud = teleport.location == .cloud
            let previous = teleport.phase
            teleport.phase = .rollingBack
            return .applied(result: {
                if interactive {
                    let go = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
                        CloudPresenter.confirm(ChiefMoveStrings.rollbackConfirmTitle, ChiefMoveStrings.rollbackConfirmBody,
                                               button: ChiefMoveStrings.rollbackButton, identifier: "cmux.dialog.chief.rollback",
                                               in: window) { done.resume(returning: $0) }
                    }
                    guard go else {
                        teleport.phase = previous
                        return .success([:])
                    }
                }
                var tokenDir: URL?
                defer { if let tokenDir { try? FileManager.default.removeItem(at: tokenDir) } }
                var tokenFile: String?
                if fromCloud {
                    do {
                        let (dir, file) = try await writeToken(cloud)
                        (tokenDir, tokenFile) = (dir, file.path)
                    } catch {
                        teleport.phase = .failed(ChiefMoveStrings.cloud, reason: String(describing: error))
                        return .failure(ActionWorkFailure(ChiefMoveStrings.rollbackFailedTitle + ": " + String(describing: error)))
                    }
                }
                let result = await run(cli, ChiefMovePlan.rollback(sourceHome: teleport.home.path, tokenFile: tokenFile),
                                          timeout: .seconds(300))
                await teleport.refresh().value
                guard result.ok else {
                    teleport.phase = previous
                    if interactive { CloudPresenter.show(ChiefMoveStrings.rollbackFailedTitle, result.text, copyable: true, in: window) }
                    return .failure(ActionWorkFailure(result.text, mayHaveApplied: true))
                }
                teleport.phase = .rolledBack
                if interactive { CloudPresenter.show(ChiefMoveStrings.rolledBackTitle, result.text, copyable: true, in: window) }
                return .success(["output": .string(result.text)])
            })
        })
    }

    /// Points the Teleport menu at the app's targets and actions, and reads where the Chief runs.
    static func bindTeleport(_ teleport: ChiefTeleportModel, registry: ActionRegistry, context: AppActionContext) {
        teleport.destinations = { targets(context).map(\.teleportDestination) }
        teleport.onMove = { [weak registry] id in
            _ = registry?.perform(actionID, invocation: ActionInvocation(arguments: ["target": .string(id)], origin: .user))
        }
        teleport.onRollback = { [weak registry] in
            _ = registry?.perform(rollbackID, invocation: ActionInvocation(origin: .user))
        }
        teleport.refresh()
    }
}
