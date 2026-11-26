public import AppKit
public import CmuxNextActions
import CmuxNextDesign
public import Foundation
import CmuxNextCompat

/// Undo Look Change (`customize.revert`, Ctrl-Opt-Cmd-Z by default): the recovery key for a look
/// that broke the window (customization capability matrix row `recovery-hotkey`). It runs the
/// bundled `cmux --json customize revert`, the verb the try-on bar's Revert Now runs (``op``), so
/// the engine stays cmux-customize's (`try_on.rs`) and nothing here decides what is put back. A
/// refusal (nothing being tried on) comes back as the action's failure, with the CLI's message.
extension CustomizeTryOnPage {
    public static let revertActionID: ActionID = "customize.revert"

    /// Binds `customize.revert` in `registry`: `cli` resolves the bundled CLI, `window` is where
    /// the toast with the action's title shows.
    public static func bindRevert(into registry: ActionRegistry, cli: @escaping @MainActor () async -> URL?,
                                  window: @escaping @MainActor () -> NSWindow?,
                                  run: @escaping @Sendable (URL, [String]) async throws -> (Int32, Data, Data) = CustomizeTryOnPage.run) {
        registry.bindEffect(revertActionID, effect: { [weak registry] _ in
            CmuxToastCenter.shared.showNotice(registry?.descriptor(for: revertActionID)?.title ?? "", id: "customizeRevert", in: window())
            return .applied(result: { await revert(cli: cli, run: run) })
        })
    }

    /// `cmux --json customize revert` through `run`: success, or the CLI's error message.
    static func revert(cli: @MainActor () async -> URL?,
                       run: @Sendable (URL, [String]) async throws -> (Int32, Data, Data)) async -> Result<[String: ActionResultValue], ActionWorkFailure> {
        guard let binary = await cli() else { return .failure(ActionWorkFailure(AppsStrings.customizeNoCLI)) }
        do {
            let (status, stdout, stderr) = try await awaitConcurrently({ try await run(binary, ["--json", "customize", "revert"]) })
            if status == 0 { return .success([:]) }
            return .failure(ActionWorkFailure(errorMessage(stderr) ?? errorMessage(stdout) ?? "cmux customize revert: exit \(status)"))
        } catch {
            return .failure(ActionWorkFailure(String(describing: error)))
        }
    }

    /// The `error.message` of the CLI's JSON envelope.
    nonisolated static func errorMessage(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? [String: Any], let text = error["message"] as? String, !text.isEmpty
        else { return nil }
        return text
    }
}
