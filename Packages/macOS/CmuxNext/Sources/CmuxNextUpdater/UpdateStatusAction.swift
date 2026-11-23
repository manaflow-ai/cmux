public import CmuxNextActions
import AppKit
import CmuxNextDesign

/// Update Status (`updates.status`): a CLI run answers ``UpdaterService/statusAnswer(now:)``'s
/// fields; a palette run shows its line as a toast on this turn. Reads only; nothing waits.
public enum UpdateStatusAction {
    /// Binds `updates.status` to `updater`.
    public static func bind(into registry: ActionRegistry, updater: UpdaterService) {
        registry.bindEffect("updates.status", effect: { [weak registry] _ in
            let fields = updater.statusAnswer()
            guard registry?.isCapturingWork != true else { return .applied(result: { .success(values(fields)) }) }
            if case .string(let line)? = fields["line"] {
                CmuxToastCenter.shared.showNotice(line, id: "updates.status", in: NSApp.mainWindow)
            }
            return .done
        })
    }

    /// An update command's answer fields as action result values (`action.run` `result`).
    nonisolated public static func values(_ fields: [String: UpdateAnswerField]) -> [String: ActionResultValue] {
        fields.mapValues { field in
            switch field {
            case .string(let text): .string(text)
            case .bool(let flag): .bool(flag)
            case .double(let number): .double(number)
            }
        }
    }
}
