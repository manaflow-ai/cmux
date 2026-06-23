public import Foundation
public import AppKit
public import UniformTypeIdentifiers

/// The frozen `com.splittabbar.tabtransfer` drag/UTType wire contract a bonsplit
/// tab carries on the `.drag` pasteboard when it is dragged between split panes,
/// windows, or onto the sidebar.
///
/// The type identifier string and the `Transfer` JSON shape are a frozen wire
/// contract: a build of cmux must read a payload written by any other build of
/// cmux (and ignore a foreign-process payload), so the UTType string, the coding
/// keys, and the legacy `sourceProcessId` default-to-`-1` decode are kept
/// byte-identical to the original inline implementation. Do not "tidy" them.
///
/// This is the pure half of the contract: the UTType identity, the `Transfer`
/// decode, and the current-process identity check, none of which reach app
/// state. The app-coupled routing half (whether a given pasteboard should be
/// routed to the workspace drop at all, and the live `.drag`-pasteboard read in
/// the former `currentTransfer()`, both of which depend on the app target's
/// `DragOverlayRoutingPolicy` file-preview/bonsplit pasteboard predicates) stays
/// app-side and calls into this core, passing its routing decision through the
/// `excludeFilePreview` parameter on ``transfer(from:excludeFilePreview:)``.
///
/// A real value type, not a caseless namespace: an instance carries the
/// `sourceProcessId` it treats as "this process" (defaulting to the live process
/// id), so the decode and identity check are instance methods bound to that
/// process identity. The frozen UTType contract constants are genuinely
/// type-level and stay `static`.
public struct BonsplitTabDragPayload: Sendable {
    /// The frozen pasteboard/UTType identifier for a bonsplit tab transfer.
    public static let typeIdentifier = "com.splittabbar.tabtransfer"

    /// The UTType exported under ``typeIdentifier``.
    public static let dropContentType = UTType(exportedAs: typeIdentifier)

    /// The drop content types accepted for a bonsplit tab drag (one element:
    /// ``dropContentType``).
    public static let dropContentTypes: [UTType] = [dropContentType]

    /// The process id this instance treats as the current process: a transfer
    /// whose `sourceProcessId` differs is a foreign-process payload and is
    /// rejected by the decode.
    public let currentProcessId: Int32

    /// Creates a decoder bound to a given current-process id. Defaults to the
    /// live process id, which is what app code uses; an explicit id is for
    /// tests that need to simulate same- vs foreign-process payloads.
    public init(currentProcessId: Int32 = Int32(ProcessInfo.processInfo.processIdentifier)) {
        self.currentProcessId = currentProcessId
    }

    /// The decoded payload of a bonsplit tab transfer.
    ///
    /// The coding keys and the legacy `sourceProcessId` default are a frozen
    /// wire contract: a payload written by an older build that omits
    /// `sourceProcessId` decodes with `-1`, which the current-process identity
    /// check then treats as a foreign process.
    public struct Transfer: Decodable, Sendable {
        /// The dragged tab's identity.
        public struct TabInfo: Decodable, Sendable {
            public let id: UUID
            public let kind: String?
        }

        public let tab: TabInfo
        public let sourcePaneId: UUID
        public let sourceProcessId: Int32

        private enum CodingKeys: String, CodingKey {
            case tab
            case sourcePaneId
            case sourceProcessId
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.tab = try container.decode(TabInfo.self, forKey: .tab)
            self.sourcePaneId = try container.decode(UUID.self, forKey: .sourcePaneId)
            // Legacy payloads won't include this field. Treat as foreign process.
            self.sourceProcessId = try container.decodeIfPresent(Int32.self, forKey: .sourceProcessId) ?? -1
        }
    }

    /// Whether `transfer` originated from the process this decoder is bound to.
    public func isCurrentProcessTransfer(_ transfer: Transfer) -> Bool {
        transfer.sourceProcessId == currentProcessId
    }

    /// The current-process bonsplit transfer on `pasteboard`, or `nil`.
    ///
    /// `excludeFilePreview` is the app-side routing decision (legacy
    /// `DragOverlayRoutingPolicy.hasFilePreviewTransfer(pasteboard.types)`): when
    /// `true`, the pasteboard is a file-preview drag and must not be read as a
    /// bonsplit transfer, so this returns `nil` immediately. The app target owns
    /// that predicate and passes its result through this parameter; the decode
    /// below is the frozen wire contract and stays here.
    public func transfer(
        from pasteboard: NSPasteboard,
        excludeFilePreview: Bool
    ) -> Transfer? {
        guard !excludeFilePreview else {
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
}
