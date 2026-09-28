import AppKit
import Foundation

extension GhosttyNSView {
    @discardableResult
    func executePreparedImageTransfer(
        _ preparedContent: TerminalImageTransferPreparedContent,
        mode: TerminalImageTransferMode = .drop,
        onCancel: @escaping () -> Void
    ) -> Bool {
        if mode == .paste, case .fileURLs(let urls) = preparedContent,
           imageTransferTargetResolution(mode: mode) == .resolved(.cloud),
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
        case .reject, .rejectOversizedImage:
            return false
        case .insertText(let text):
            return terminalSurface?.sendText(text) ?? false
        case .fileURLs(let fileURLs):
            switch imageTransferTargetResolution(mode: mode) {
            case .resolved(let target):
                return executeFileTransfer(
                    fileURLs,
                    preparedContent: preparedContent,
                    target: target,
                    mode: mode,
                    onCancel: onCancel
                )
            case .detectSSHSession(let ttyName):
                // Accept the drop or paste now. The SSH check reads the process
                // table, which stalls the main thread for seconds on a loaded Mac.
                MainActor.assumeIsolated {
                    Task { @MainActor [weak self] in
                        let target = await Task.detached(priority: .userInitiated) {
                            TerminalImageTransferTargetResolution.target(detectedOn: ttyName)
                        }.value
                        guard let self else {
                            preparedContent.cleanupTransferredTemporaryFiles(
                                using: GhosttyApp.terminalPasteboard
                            )
                            return
                        }
                        _ = self.executeFileTransfer(
                            fileURLs,
                            preparedContent: preparedContent,
                            target: target,
                            mode: mode,
                            onCancel: onCancel
                        )
                    }
                }
                return true
            }
        }
    }

    private func executeFileTransfer(
        _ fileURLs: [URL],
        preparedContent: TerminalImageTransferPreparedContent,
        target: TerminalImageTransferTarget,
        mode: TerminalImageTransferMode,
        onCancel: @escaping () -> Void
    ) -> Bool {
        let plan = TerminalImageTransferPlanner.plan(
            fileURLs: fileURLs,
            target: target,
            mode: mode
        )
        guard plan != .reject else {
            preparedContent.cleanupTransferredTemporaryFiles(
                using: GhosttyApp.terminalPasteboard
            )
            return false
        }
        return executeImageTransferPlan(
            plan,
            onCancel: onCancel
        )
    }

    func handleDroppedFileURLs(_ urls: [URL], pasteboard: NSPasteboard? = nil) -> Bool {
        if let pasteboard {
            return insertDroppedPasteboard(pasteboard)
        }
        let dragTypes = NSPasteboard(name: .drag).types ?? []
        guard let durableURLs = GhosttyApp.terminalPasteboard.durableDroppedFileURLs(
            urls,
            sourceIsTransient: PasteboardFileURLReader.hasPromisedFileURLType(
                dragTypes
            )
        ) else {
            return false
        }
        return executePreparedImageTransfer(
            .fileURLs(durableURLs),
            onCancel: {}
        )
    }

    @discardableResult
    func insertDroppedPasteboard(_ pasteboard: NSPasteboard) -> Bool {
        let prepared = TerminalImageTransferPlanner.prepareSynchronously(
            pasteboard: pasteboard,
            mode: .drop
        )
#if DEBUG
        cmuxDebugLog("terminal.imageDrop.prepared surface=\(terminalSurface?.id.uuidString.prefix(5) ?? "nil") " +
            "types=\((pasteboard.types ?? []).map(\.rawValue).joined(separator: ",")) prepared=\(prepared.cmuxDebugDescription)")
#endif
        return executePreparedImageTransfer(prepared, onCancel: {})
    }
}
