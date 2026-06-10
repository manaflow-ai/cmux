import Foundation
import CmuxTerminalCopyMode
import CmuxSocketControl
import SwiftUI
import AppKit
import Metal
import QuartzCore
import Combine
import CoreText
import Darwin
import Carbon.HIToolbox
import os
import Sentry
import Bonsplit
import CMUXAgentLaunch
import CMUXMobileCore
import CMUXPasteboardFidelity
import IOSurface
import UniformTypeIdentifiers


// MARK: - Runtime clipboard read callback
extension GhosttyApp {
    static func runtimeReadClipboardCallback(
        _ userdata: UnsafeMutableRawPointer?,
        _ location: ghostty_clipboard_e,
        _ state: UnsafeMutableRawPointer?
    ) -> Bool {
        guard let callbackContext = Self.callbackContext(from: userdata),
              let requestSurface = callbackContext.runtimeSurface else { return false }

        DispatchQueue.main.async {
            func completeClipboardRequest(with text: String) {
                let finish = {
                    guard callbackContext.runtimeSurface == requestSurface else { return }
                    text.withCString { ptr in
                        ghostty_surface_complete_clipboard_request(requestSurface, ptr, state, false)
                    }
                    callbackContext.terminalSurface?.noteClipboardReadCompleted()
                }
                if Thread.isMainThread {
                    finish()
                } else {
                    DispatchQueue.main.async(execute: finish)
                }
            }

            guard let pasteboard = GhosttyPasteboardHelper.pasteboard(for: location) else {
                completeClipboardRequest(with: "")
                return
            }

            let preparedContent = TerminalImageTransferPlanner.prepare(
                pasteboard: pasteboard,
                mode: .paste
            )

#if DEBUG
            cmuxDebugLog(
                "terminal.clipboard.read surface=\(callbackContext.surfaceId.uuidString.prefix(5)) " +
                "types=\((pasteboard.types ?? []).map(\.rawValue).joined(separator: ",")) " +
                "prepared=\(Self.debugDescription(for: preparedContent))"
            )
#endif

            switch preparedContent {
            case .reject:
                completeClipboardRequest(with: "")
            case .insertText(let text):
                completeClipboardRequest(with: text)
            case .fileURLs(let fileURLs):
                let operation = TerminalImageTransferOperation()
                MainActor.assumeIsolated {
                    callbackContext.terminalSurface?.hostedView.beginImageTransferIndicator(
                        for: operation,
                        onCancel: {
                            completeClipboardRequest(with: "")
                        }
                    )
                }

                let target = MainActor.assumeIsolated {
                    callbackContext.terminalSurface?.resolvedImageTransferTarget() ?? .local
                }
                let plan = TerminalImageTransferPlanner.plan(
                    fileURLs: fileURLs,
                    target: target
                )

                TerminalImageTransferPlanner.execute(
                    plan: plan,
                    operation: operation,
                    uploadWorkspaceRemote: { fileURLs, operation, finish in
                        guard let workspace = MainActor.assumeIsolated({
                            callbackContext.terminalSurface?.owningWorkspace()
                        }) else {
                            finish(.failure(NSError(domain: "cmux.remote.paste", code: 3)))
                            GhosttyPasteboardHelper.cleanupTransferredTemporaryImageFiles(fileURLs)
                            return
                        }
                        workspace.uploadDroppedFilesForRemoteTerminal(
                            fileURLs,
                            operation: operation,
                            completion: { result in
                                finish(result)
                                GhosttyPasteboardHelper.cleanupTransferredTemporaryImageFiles(fileURLs)
                            }
                        )
                    },
                    uploadDetectedSSH: { session, fileURLs, operation, finish in
                        session.uploadDroppedFiles(
                            fileURLs,
                            operation: operation,
                            completion: { result in
                                finish(result)
                                GhosttyPasteboardHelper.cleanupTransferredTemporaryImageFiles(fileURLs)
                            }
                        )
                    },
                    insertText: { text in
                        MainActor.assumeIsolated {
                            callbackContext.terminalSurface?.hostedView.endImageTransferIndicator(
                                for: operation
                            )
                        }
                        completeClipboardRequest(with: text)
                    },
                    onFailure: { _ in
                        MainActor.assumeIsolated {
                            callbackContext.terminalSurface?.hostedView.endImageTransferIndicator(
                                for: operation
                            )
                        }
                        NSSound.beep()
#if DEBUG
                        cmuxDebugLog("terminal.remotePasteUpload.failed surface=\(callbackContext.surfaceId.uuidString.prefix(5))")
#endif
                        completeClipboardRequest(with: "")
                    }
                )
            }
        }

        return true
    }

}
