public import CmuxNextControl
import CmuxNextPages
import CmuxNextSettings
import CmuxNextUpdater
import Foundation

// Web updates (plans/cmux-next/web-ota.md). `updates.web.status`: the channel, the update served
// now and the one ready for the next safe point, the bundled web's abi, the last check.
// `updates.web.check`: reads the channel's pointer now and answers with the status (`pending`
// while a download outlasts the control deadline).
// `updates.web.rollback`: serves the update before the active one (the bundled web when none) at
// the next safe point; the rolled-back update is not taken again. `updates.web.apply`: swaps a
// ready update in now and reloads the pages, past the safe point's checks (WebSwapGate): an
// explicit ask, for tests and support; a draft being typed is not saved first.
extension WebUpdates {
    /// The `updates.web.*` methods, for the App's control router.
    public var controlMethods: [ControlMethod] {
        let web = self
        return [
            .mainActor("updates.web.status") { _ in .value(Self.json(web)) },
            .mainActor("updates.web.check") { call in
                guard let updater = web.updater else { return .value(Self.json(web)) }
                // Answer inside the control deadline. A slower check (a download) keeps running:
                // `pending: true`, then read `updates.web.status`.
                // task-owner: one check; it ends by itself
                let check = Task { await updater.check() }
                let answerBy = call.deadline - .milliseconds(150)
                return .followUp {
                    let done = (try? await ControlDeadline.shared.run(method: call.method, deadline: answerBy) { await check.value }) != nil
                    return await MainActor.run {
                        guard case .object(var fields) = Self.json(web) else { return .null }
                        fields["pending"] = .bool(!done || updater.phase == .checking || updater.phase == .downloading)
                        return .object(fields)
                    }
                }
            },
            .mainActor("updates.web.rollback") { _ in
                guard let updater = web.updater else {
                    throw ControlError(code: "web_updates_unavailable", message: "web updates run on NIGHTLY builds only")
                }
                guard updater.state.active != nil else {
                    throw ControlError(code: "rollback_refused", message: "the bundled web is already served")
                }
                return .followUp {
                    try await updater.rollBack()
                    return await MainActor.run { Self.json(web) }
                }
            },
            .mainActor("updates.web.apply") { _ in
                let reloaded = web.applyPending()
                guard case .object(var fields) = Self.json(web) else { return .value(.null) }
                fields["reloaded"] = JSONValue(reloaded)
                return .value(.object(fields))
            },
        ]
    }

    static func json(_ web: WebUpdates) -> JSONValue {
        guard let updater = web.updater else { return .object(["available": .bool(false)]) }
        let pending: JSONValue = switch web.pending {
        case .none: .null
        case .some(nil): .string("bundled")
        case .some(.some(let tree)): .string(tree.lastPathComponent)
        }
        return .object([
            "available": .bool(true),
            "channel": .string(updater.channel.rawValue),
            "phase": .string(json(updater.phase)),
            "active": updater.state.active.map(json) ?? .null,
            "previous": updater.state.previous.map(json) ?? .null,
            "served": WebBundleOverlay.shared.activeTree.map { .string($0.lastPathComponent) } ?? .string("bundled"),
            "pending": pending,
            // What held the pending update at the last safe point look (WebSwapGate): app input,
            // a sheet, or a page's own reason (`composer.sending`, `selection`, `page.no-answer`).
            "waiting_for": web.pending == nil ? .null : web.heldBy.map { .string($0) } ?? .null,
            "app_abi": JSONValue(updater.app.abi),
            "app_web_built_at": JSONValue(updater.app.webBuiltAt),
            "last_check": updater.lastCheck.map { .string(ISO8601DateFormatter().string(from: $0)) } ?? .null,
            "last_refusal": updater.lastRefusal.map { .string(String(describing: $0)) } ?? .null,
        ])
    }

    private static func json(_ phase: WebUpdater.Phase) -> String {
        switch phase {
        case .idle: "idle"
        case .checking: "checking"
        case .downloading: "downloading"
        case .failed(let message): "failed: \(message)"
        }
    }

    private static func json(_ pointer: WebUpdatePointer) -> JSONValue {
        .object([
            "key": .string(pointer.key), "commit": .string(pointer.commit), "abi": JSONValue(pointer.abi),
            "committed_at": JSONValue(pointer.committedAt), "size": JSONValue(pointer.size),
        ])
    }
}
