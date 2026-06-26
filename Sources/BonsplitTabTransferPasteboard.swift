import AppKit
import Foundation
import UniformTypeIdentifiers

/// Parses the `com.splittabbar.tabtransfer` drag pasteboard that the bonsplit
/// tab bar writes when a tab is dragged, decoding it into a ``Transfer`` and
/// gating it to drags that originated in this process.
///
/// This is a value-typed parser, not a namespace: it holds the
/// ``currentProcessId`` it validates against (injected for testability,
/// defaulting to the running process) and exposes its read methods as instance
/// methods. The `com.splittabbar.tabtransfer` UTI metadata is shared, immutable
/// constants and stays `static`.
struct BonsplitTabTransferPasteboard {
    /// The decoded bonsplit tab-transfer payload carried on the drag
    /// pasteboard. `Sendable` so it can cross isolation boundaries between the
    /// AppKit drop delegates and the workspace-move handlers.
    struct Transfer: Decodable, Sendable {
        struct TabInfo: Decodable, Sendable {
            let id: UUID
            let kind: String?
        }

        let tab: TabInfo
        let sourcePaneId: UUID
        let sourceProcessId: Int32

        private enum CodingKeys: String, CodingKey {
            case tab
            case sourcePaneId
            case sourceProcessId
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.tab = try container.decode(TabInfo.self, forKey: .tab)
            self.sourcePaneId = try container.decode(UUID.self, forKey: .sourcePaneId)
            // Legacy payloads won't include this field. Treat as foreign process.
            self.sourceProcessId = try container.decodeIfPresent(Int32.self, forKey: .sourceProcessId) ?? -1
        }
    }

    /// The exported UTI for the bonsplit tab-transfer drag payload. Declared in
    /// `Resources/Info.plist` under `UTExportedTypeDeclarations`.
    static let typeIdentifier = "com.splittabbar.tabtransfer"
    /// The `UTType` form of ``typeIdentifier`` for SwiftUI `onDrop`/AppKit
    /// registration.
    static let dropContentType = UTType(exportedAs: typeIdentifier)
    /// Single-element content-type list for `onDrop(of:)`.
    static let dropContentTypes: [UTType] = [dropContentType]

    /// The process id this parser accepts transfers from. Drags from another
    /// cmux process are rejected so a tab cannot be torn across windows of
    /// different processes.
    let currentProcessId: Int32

    init(currentProcessId: Int32 = ProcessInfo.processInfo.processIdentifier) {
        self.currentProcessId = currentProcessId
    }

    /// Reads the active drag pasteboard for a same-process bonsplit transfer.
    func currentTransfer() -> Transfer? {
        transfer(from: NSPasteboard(name: .drag))
    }

    /// Whether a workspace drop overlay should route the given pasteboard types:
    /// it carries a bonsplit tab transfer and is not a file-preview drag.
    func canRouteWorkspaceDrop(_ pasteboardTypes: [NSPasteboard.PasteboardType]?) -> Bool {
        DragOverlayRoutingPolicy.hasBonsplitTabTransfer(pasteboardTypes)
            && !DragOverlayRoutingPolicy.hasFilePreviewTransfer(pasteboardTypes)
    }

    /// Decodes a same-process ``Transfer`` from the given pasteboard, trying the
    /// binary data representation first and the UTF-8 string fallback second.
    func transfer(from pasteboard: NSPasteboard) -> Transfer? {
        guard !DragOverlayRoutingPolicy.hasFilePreviewTransfer(pasteboard.types) else {
            return nil
        }
        let type = NSPasteboard.PasteboardType(Self.typeIdentifier)

        if let data = pasteboard.data(forType: type),
           let transfer = try? JSONDecoder().decode(Transfer.self, from: data),
           isCurrentProcessTransfer(transfer) {
            return transfer
        }

        if let raw = pasteboard.string(forType: type),
           let data = raw.data(using: .utf8),
           let transfer = try? JSONDecoder().decode(Transfer.self, from: data),
           isCurrentProcessTransfer(transfer) {
            return transfer
        }

        return nil
    }

    private func isCurrentProcessTransfer(_ transfer: Transfer) -> Bool {
        transfer.sourceProcessId == currentProcessId
    }
}
