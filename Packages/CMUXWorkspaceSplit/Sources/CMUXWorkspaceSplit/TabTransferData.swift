import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Custom UTTypes for tab drag and drop
extension UTType {
    static var tabItem: UTType {
        UTType(exportedAs: "com.splittabbar.tabitem")
    }

    static var tabTransfer: UTType {
        UTType(exportedAs: "com.splittabbar.tabtransfer", conformingTo: .data)
    }
}

/// Transfer data that includes source pane information for cross-pane moves
struct TabTransferData: Codable, Transferable {
    struct LegacyTabInfo: Codable {
        let id: UUID
    }

    let tabId: TabID
    let sourcePaneId: UUID
    let sourceProcessId: Int32

    init(tabId: TabID, sourcePaneId: UUID, sourceProcessId: Int32 = Int32(ProcessInfo.processInfo.processIdentifier)) {
        self.tabId = tabId
        self.sourcePaneId = sourcePaneId
        self.sourceProcessId = sourceProcessId
    }

    var isFromCurrentProcess: Bool {
        sourceProcessId == Int32(ProcessInfo.processInfo.processIdentifier)
    }

    enum CodingKeys: String, CodingKey {
        case tabId
        case tab
        case sourcePaneId
        case sourceProcessId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let tabId = try container.decodeIfPresent(TabID.self, forKey: .tabId) {
            self.tabId = tabId
        } else if let legacyTab = try container.decodeIfPresent(LegacyTabInfo.self, forKey: .tab) {
            self.tabId = TabID(id: legacyTab.id)
        } else {
            let legacyTab = try container.decode(WorkspaceLayout.Tab.self, forKey: .tab)
            self.tabId = legacyTab.id
        }
        self.sourcePaneId = try container.decode(UUID.self, forKey: .sourcePaneId)
        // Legacy payloads won't include this field. Treat as foreign process to reject cross-instance drops.
        self.sourceProcessId = try container.decodeIfPresent(Int32.self, forKey: .sourceProcessId) ?? -1
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(tabId, forKey: .tabId)
        // Keep legacy tab.id payload for older in-process drop consumers.
        try container.encode(LegacyTabInfo(id: tabId.id), forKey: .tab)
        try container.encode(sourcePaneId, forKey: .sourcePaneId)
        try container.encode(sourceProcessId, forKey: .sourceProcessId)
    }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .tabTransfer)
    }
}
