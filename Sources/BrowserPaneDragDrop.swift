import AppKit
import Bonsplit
import ObjectiveC
import SwiftUI
import WebKit


struct BrowserPaneDropContext: Equatable {
    let workspaceId: UUID
    let panelId: UUID
    let paneId: PaneID
}

struct BrowserPaneDragTransfer: Equatable {
    let tabId: UUID
    let sourcePaneId: UUID
    let sourceProcessId: Int32
    let kind: String?
    let isFilePreviewTransfer: Bool

    init(
        tabId: UUID,
        sourcePaneId: UUID,
        sourceProcessId: Int32,
        kind: String? = nil,
        isFilePreviewTransfer: Bool = false
    ) {
        self.tabId = tabId
        self.sourcePaneId = sourcePaneId
        self.sourceProcessId = sourceProcessId
        self.kind = kind
        self.isFilePreviewTransfer = isFilePreviewTransfer
    }

    var isFromCurrentProcess: Bool {
        sourceProcessId == Int32(ProcessInfo.processInfo.processIdentifier)
    }

    var isFilePreview: Bool {
        isFilePreviewTransfer
    }

    static func decode(from pasteboard: NSPasteboard) -> BrowserPaneDragTransfer? {
        if let data = pasteboard.data(forType: DragOverlayRoutingPolicy.filePreviewTransferType) {
            return decode(from: data, isFilePreviewTransfer: true)
        }
        if let raw = pasteboard.string(forType: DragOverlayRoutingPolicy.filePreviewTransferType) {
            return decode(from: Data(raw.utf8), isFilePreviewTransfer: true)
        }
        if let data = pasteboard.data(forType: DragOverlayRoutingPolicy.bonsplitTabTransferType) {
            return decode(from: data)
        }
        if let raw = pasteboard.string(forType: DragOverlayRoutingPolicy.bonsplitTabTransferType) {
            return decode(from: Data(raw.utf8))
        }
        return nil
    }

    static func decode(from data: Data, isFilePreviewTransfer: Bool = false) -> BrowserPaneDragTransfer? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tab = json["tab"] as? [String: Any],
              let tabIdRaw = tab["id"] as? String,
              let tabId = UUID(uuidString: tabIdRaw),
              let sourcePaneIdRaw = json["sourcePaneId"] as? String,
              let sourcePaneId = UUID(uuidString: sourcePaneIdRaw) else {
            return nil
        }

        let sourceProcessId = (json["sourceProcessId"] as? NSNumber)?.int32Value ?? -1
        let kind = tab["kind"] as? String
        return BrowserPaneDragTransfer(
            tabId: tabId,
            sourcePaneId: sourcePaneId,
            sourceProcessId: sourceProcessId,
            kind: kind,
            isFilePreviewTransfer: isFilePreviewTransfer
        )
    }
}

struct BrowserPaneSplitTarget: Equatable {
    let orientation: SplitOrientation
    let insertFirst: Bool
}

enum BrowserPaneDropAction: Equatable {
    case noOp
    case move(
        tabId: UUID,
        targetWorkspaceId: UUID,
        targetPane: PaneID,
        splitTarget: BrowserPaneSplitTarget?
    )
}

enum BrowserPaneDropRouting {
    static func zone(for location: CGPoint, in size: CGSize, topChromeHeight: CGFloat = 0) -> DropZone {
        PaneDropRouting.zone(for: location, in: size, topChromeHeight: topChromeHeight)
    }

    static func overlayFrame(for zone: DropZone, in size: CGSize, topChromeHeight: CGFloat = 0) -> CGRect {
        PaneDropRouting.compactOverlayFrame(for: zone, in: size, topChromeHeight: topChromeHeight)
    }

    static func action(
        for transfer: BrowserPaneDragTransfer,
        target: BrowserPaneDropContext,
        zone: DropZone
    ) -> BrowserPaneDropAction? {
        if zone == .center, transfer.sourcePaneId == target.paneId.id {
            return .noOp
        }

        let splitTarget: BrowserPaneSplitTarget?
        switch zone {
        case .center:
            splitTarget = nil
        case .left:
            splitTarget = BrowserPaneSplitTarget(orientation: .horizontal, insertFirst: true)
        case .right:
            splitTarget = BrowserPaneSplitTarget(orientation: .horizontal, insertFirst: false)
        case .top:
            splitTarget = BrowserPaneSplitTarget(orientation: .vertical, insertFirst: true)
        case .bottom:
            splitTarget = BrowserPaneSplitTarget(orientation: .vertical, insertFirst: false)
        }

        return .move(
            tabId: transfer.tabId,
            targetWorkspaceId: target.workspaceId,
            targetPane: target.paneId,
            splitTarget: splitTarget
        )
    }

    static func filePreviewDestination(
        target: BrowserPaneDropContext,
        zone: DropZone
    ) -> BonsplitController.ExternalTabDropRequest.Destination {
        PaneDropRouting.filePreviewDestination(targetPane: target.paneId, zone: zone)
    }
}

