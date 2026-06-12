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


// MARK: - Drag and drop
extension GhosttyNSView {
    static func dropPlanForTesting(
        pasteboard: NSPasteboard,
        isRemoteTerminalSurface: Bool
    ) -> DropPlan {
        let target: TerminalImageTransferTarget = isRemoteTerminalSurface ? .remote(.workspaceRemote) : .local
        switch TerminalImageTransferPlanner.plan(
            pasteboard: pasteboard,
            mode: .drop,
            target: target
        ) {
        case .insertText(let text):
            return .insertText(text)
        case .insertTextSegments(let segments, _):
            return .insertText(segments.joined())
        case .uploadFiles(let fileURLs, _):
            return .uploadFiles(fileURLs)
        case .reject:
            return .reject
        }
    }

    @discardableResult
    static func handleDropForTesting(
        pasteboard: NSPasteboard,
        isRemoteTerminalSurface: Bool,
        uploadRemote: ([URL], @escaping (Result<[String], Error>) -> Void) -> Void,
        sendText: @escaping (String) -> Void,
        onFailure: @escaping () -> Void
    ) -> Bool {
        let target: TerminalImageTransferTarget = isRemoteTerminalSurface ? .remote(.workspaceRemote) : .local
        let plan = TerminalImageTransferPlanner.plan(
            pasteboard: pasteboard,
            mode: .drop,
            target: target
        )
        guard plan != .reject else { return false }

        TerminalImageTransferPlanner.execute(
            plan: plan,
            uploadWorkspaceRemote: { urls, _, finish in
                uploadRemote(urls) { result in
                    finish(result)
                    GhosttyPasteboardHelper.cleanupTransferredTemporaryImageFiles(urls)
                }
            },
            uploadDetectedSSH: { _, _, _, finish in
                finish(.failure(NSError(domain: "cmux.remote.drop", code: 4)))
            },
            insertText: sendText,
            onFailure: { _ in onFailure() }
        )
        return true
    }

    private func executeImageTransferPlan(
        _ plan: TerminalImageTransferPlan,
        operation: TerminalImageTransferOperation? = nil,
        onCancel: @escaping () -> Void = {}
    ) -> Bool {
        guard plan != .reject else { return false }

        let operation = operation ?? {
            if case .uploadFiles = plan {
                return TerminalImageTransferOperation()
            }
            return nil
        }()

        if let operation {
            terminalSurface?.hostedView.beginImageTransferIndicator(
                for: operation,
                onCancel: onCancel
            )
        }

        TerminalImageTransferPlanner.execute(
            plan: plan,
            operation: operation,
            uploadWorkspaceRemote: { [weak self] fileURLs, operation, finish in
                guard let workspace = MainActor.assumeIsolated({
                    self?.terminalSurface?.owningWorkspace()
                }) else {
                    finish(.failure(NSError(domain: "cmux.remote.drop", code: 3)))
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
            insertText: { [weak self] text in
                let send = {
                    if let operation {
                        self?.terminalSurface?.hostedView.endImageTransferIndicator(for: operation)
                    }
                    // Use the text/paste path (ghostty_surface_text) instead of the key event
                    // path (ghostty_surface_key) so bracketed paste mode is triggered and the
                    // insertion is instant, matching upstream Ghostty behaviour.
                    self?.terminalSurface?.sendText(text)
                }
                if Thread.isMainThread {
                    send()
                } else {
                    DispatchQueue.main.async(execute: send)
                }
            },
            onFailure: { [weak self] _ in
                if let operation {
                    self?.terminalSurface?.hostedView.endImageTransferIndicator(for: operation)
                }
                DispatchQueue.main.async {
                    NSSound.beep()
#if DEBUG
                    cmuxDebugLog("terminal.remoteDropUpload.failed surface=\(self?.terminalSurface?.id.uuidString.prefix(5) ?? "nil")")
#endif
                }
            }
        )
        return true
    }

    private func resolvedImageTransferTarget() -> TerminalImageTransferTarget {
        MainActor.assumeIsolated {
            terminalSurface?.resolvedImageTransferTarget() ?? .local
        }
    }

    func handleDroppedFileURLs(_ urls: [URL]) -> Bool {
        executePreparedImageTransfer(
            .fileURLs(urls),
            onCancel: {}
        )
    }

    @discardableResult
    fileprivate func insertDroppedPasteboard(_ pasteboard: NSPasteboard) -> Bool {
        executePreparedImageTransfer(
            TerminalImageTransferPlanner.prepare(
                pasteboard: pasteboard,
                mode: .drop
            ),
            onCancel: {}
        )
    }

    @discardableResult
    private func executePreparedImageTransfer(
        _ preparedContent: TerminalImageTransferPreparedContent,
        onCancel: @escaping () -> Void
    ) -> Bool {
        switch preparedContent {
        case .reject:
            return false
        case .insertText(let text):
            terminalSurface?.sendText(text)
            return true
        case .fileURLs(let fileURLs):
            let plan = TerminalImageTransferPlanner.plan(
                fileURLs: fileURLs,
                target: resolvedImageTransferTarget(),
                mode: .drop
            )
            return executeImageTransferPlan(plan, onCancel: onCancel)
        }
    }

#if DEBUG
    fileprivate enum DebugDropPayloadKind {
        case fileURLs
        case imageData
    }

    @discardableResult
    func debugSimulateFileDrop(
        paths: [String],
        asImageData: Bool = false
    ) -> Bool {
        guard !paths.isEmpty else { return false }
        let pbName = NSPasteboard.Name("cmux.debug.drop.\(UUID().uuidString)")
        let pasteboard = NSPasteboard(name: pbName)
        pasteboard.clearContents()
        switch asImageData ? DebugDropPayloadKind.imageData : .fileURLs {
        case .fileURLs:
            let urls = paths.map { URL(fileURLWithPath: $0) as NSURL }
            pasteboard.writeObjects(urls)
        case .imageData:
            let items = paths.compactMap { path -> NSPasteboardItem? in
                let url = URL(fileURLWithPath: path)
                guard let data = try? Data(contentsOf: url),
                      let type = debugImagePasteboardType(for: url) else { return nil }
                let item = NSPasteboardItem()
                item.setData(data, forType: type)
                return item
            }
            guard items.count == paths.count else { return false }
            pasteboard.writeObjects(items)
        }
        return insertDroppedPasteboard(pasteboard)
    }

    private func debugImagePasteboardType(for url: URL) -> NSPasteboard.PasteboardType? {
        let pathExtension = url.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let utType = UTType(filenameExtension: pathExtension),
              utType.conforms(to: .image) else { return nil }
        return NSPasteboard.PasteboardType(utType.identifier)
    }

    func debugRegisteredDropTypes() -> [String] {
        (registeredDraggedTypes ?? []).map(\.rawValue)
    }
#endif

    // MARK: NSDraggingDestination

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        #if DEBUG
        let types = sender.draggingPasteboard.types ?? []
        cmuxDebugLog("terminal.draggingEntered surface=\(terminalSurface?.id.uuidString.prefix(5) ?? "nil") types=\(types.map(\.rawValue))")
        #endif
        guard let types = sender.draggingPasteboard.types else { return [] }
        // Defer to bonsplit when a tab/session drag is in flight: bonsplit's pane
        // drop overlays should win over the terminal's text/file drop handling.
        if types.contains(Self.tabTransferPasteboardType) || types.contains(Self.sidebarTabReorderPasteboardType) {
            return []
        }
        if Set(types).isDisjoint(with: Self.dropTypes) {
            return []
        }
        return .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        #if DEBUG
        let types = sender.draggingPasteboard.types ?? []
        cmuxDebugLog("terminal.draggingUpdated surface=\(terminalSurface?.id.uuidString.prefix(5) ?? "nil") types=\(types.map(\.rawValue))")
        #endif
        guard let types = sender.draggingPasteboard.types else { return [] }
        if types.contains(Self.tabTransferPasteboardType) || types.contains(Self.sidebarTabReorderPasteboardType) {
            return []
        }
        if Set(types).isDisjoint(with: Self.dropTypes) {
            return []
        }
        return .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let types = sender.draggingPasteboard.types ?? []
        if types.contains(Self.tabTransferPasteboardType) || types.contains(Self.sidebarTabReorderPasteboardType) {
            return false
        }
        #if DEBUG
        cmuxDebugLog("terminal.fileDrop surface=\(terminalSurface?.id.uuidString.prefix(5) ?? "nil")")
        #endif
        return insertDroppedPasteboard(sender.draggingPasteboard)
    }
}
