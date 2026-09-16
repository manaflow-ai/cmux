import Foundation

extension GhosttyNSView {
    @discardableResult
    func executePreparedImageTransfer(
        _ preparedContent: TerminalImageTransferPreparedContent,
        mode: TerminalImageTransferMode = .drop,
        onCancel: @escaping () -> Void
    ) -> Bool {
        if mode == .paste, case .fileURLs(let urls) = preparedContent,
           resolvedImageTransferTarget(mode: mode) == .cloud,
           deferRuntimeInputDuringClipboardRead(estimatedBytes: urls.reduce(0) { $0 + $1.path.utf8.count + 256 }, replay: { [weak self] in
               if let self {
                   _ = self.executePreparedImageTransfer(preparedContent, mode: mode, onCancel: onCancel)
               } else {
                   preparedContent.cleanupTransferredTemporaryFiles(using: GhosttyApp.terminalPasteboard)
               }
           }) {
            return true
        }
        switch preparedContent {
        case .reject:
            return false
        case .insertText(let text):
            return terminalSurface?.sendText(text) ?? false
        case .fileURLs(let fileURLs):
            let plan = TerminalImageTransferPlanner.plan(
                fileURLs: fileURLs,
                target: resolvedImageTransferTarget(mode: mode),
                mode: mode
            )
            guard plan != .reject else {
                preparedContent.cleanupTransferredTemporaryFiles(
                    using: GhosttyApp.terminalPasteboard
                )
                return false
            }
            let onTextCompletion: () -> Void
            switch plan {
            case .insertText:
                onTextCompletion = {
                    preparedContent.cleanupTransferredTemporaryFiles(
                        using: GhosttyApp.terminalPasteboard
                    )
                }
            case .insertTextSegments(let segments, _):
                var remainingSegments = segments.count
                onTextCompletion = {
                    remainingSegments = max(0, remainingSegments - 1)
                    guard remainingSegments == 0 else { return }
                    preparedContent.cleanupTransferredTemporaryFiles(
                        using: GhosttyApp.terminalPasteboard
                    )
                }
            case .uploadFiles, .pasteCloudImages:
                onTextCompletion = {}
            case .reject:
                onTextCompletion = {}
            }
            return executeImageTransferPlan(
                plan,
                onCancel: onCancel,
                onTextCompletion: onTextCompletion
            )
        }
    }
}
