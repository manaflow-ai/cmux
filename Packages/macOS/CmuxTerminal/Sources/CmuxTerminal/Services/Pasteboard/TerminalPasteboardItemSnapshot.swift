public import AppKit
public import Foundation

/// A Sendable, eagerly materialized pasteboard item.
public struct TerminalPasteboardItemSnapshot: Codable, Equatable, Sendable {
    /// One pasteboard flavor and its materialized bytes.
    public struct Representation: Codable, Equatable, Sendable {
        /// The Uniform Type Identifier written to the pasteboard.
        public let typeIdentifier: String

        /// The bytes for this flavor.
        public let data: Data

        /// Creates one materialized pasteboard flavor.
        public init(typeIdentifier: String, data: Data) {
            self.typeIdentifier = typeIdentifier
            self.data = data
        }
    }

    /// Every flavor on the item, in pasteboard order.
    public let representations: [Representation]

    /// Creates a pasteboard item from materialized flavors.
    public init(representations: [Representation]) {
        self.representations = representations
    }

    init(item: NSPasteboardItem) {
        representations = item.types.compactMap { type in
            guard let data = item.data(forType: type) else { return nil }
            return Representation(
                typeIdentifier: type.rawValue,
                data: data
            )
        }
    }

    var retainedByteCount: Int {
        representations.reduce(into: 0) { total, representation in
            let (representationBytes, representationOverflowed) =
                representation.typeIdentifier.utf8.count
                .addingReportingOverflow(representation.data.count)
            guard !representationOverflowed else {
                total = .max
                return
            }
            let (newTotal, overflowed) = total.addingReportingOverflow(
                representationBytes
            )
            total = overflowed ? .max : newTotal
        }
    }

    func makePasteboardItem() -> NSPasteboardItem? {
        guard !representations.isEmpty else { return nil }
        let item = NSPasteboardItem()
        var wroteRepresentation = false
        for representation in representations {
            wroteRepresentation = item.setData(
                representation.data,
                forType: NSPasteboard.PasteboardType(
                    representation.typeIdentifier
                )
            ) || wroteRepresentation
        }
        return wroteRepresentation ? item : nil
    }
}

extension TerminalPasteboardItemSnapshot {
    static func snapshots(
        from items: [NSPasteboardItem]
    ) -> [TerminalPasteboardItemSnapshot] {
        items.map(TerminalPasteboardItemSnapshot.init(item:))
            .filter { !$0.representations.isEmpty }
    }

    /// Eagerly captures every materializable item up to a retained-byte cap.
    ///
    /// Callers resolving an external pasteboard must invoke this in the
    /// killable paste worker because an item data provider may block.
    public static func captureContents(
        of pasteboard: NSPasteboard,
        maximumByteCount: Int
    ) -> [TerminalPasteboardItemSnapshot]? {
        let maximumByteCount = max(0, maximumByteCount)
        var retainedBytes = 0
        var snapshots: [TerminalPasteboardItemSnapshot] = []
        for item in pasteboard.pasteboardItems ?? [] {
            let snapshot = TerminalPasteboardItemSnapshot(item: item)
            guard !snapshot.representations.isEmpty else { continue }
            let snapshotBytes = snapshot.retainedByteCount
            guard snapshotBytes <= maximumByteCount,
                  retainedBytes <= maximumByteCount - snapshotBytes else {
                return nil
            }
            retainedBytes += snapshotBytes
            snapshots.append(snapshot)
        }
        return snapshots
    }

    static func retainedByteCount(
        of snapshots: [TerminalPasteboardItemSnapshot]
    ) -> Int {
        snapshots.reduce(into: 0) { total, snapshot in
            let snapshotBytes = snapshot.retainedByteCount
            let (newTotal, overflowed) = total.addingReportingOverflow(
                snapshotBytes
            )
            total = overflowed ? .max : newTotal
        }
    }
}

/// One bounded request to snapshot a stable generation of a named pasteboard.
public struct TerminalPasteboardContentsCaptureRequest: Codable, Sendable {
    /// The AppKit pasteboard name to open in the isolated worker.
    public let pasteboardName: String

    /// The generation that must remain current throughout materialization.
    public let changeCount: Int

    /// The maximum retained bytes allowed in the returned snapshot.
    public let maximumByteCount: Int

    /// Creates a stable-generation pasteboard capture request.
    public init(
        pasteboardName: String,
        changeCount: Int,
        maximumByteCount: Int
    ) {
        self.pasteboardName = pasteboardName
        self.changeCount = changeCount
        self.maximumByteCount = maximumByteCount
    }
}

/// Fully materialized contents from one unchanged pasteboard generation.
public struct TerminalPasteboardContentsSnapshot:
    Codable,
    Equatable,
    Sendable
{
    /// The generation observed before and after materialization.
    public let changeCount: Int

    /// Every bounded, eagerly materialized pasteboard item.
    public let contents: [TerminalPasteboardItemSnapshot]

    /// Creates a stable pasteboard snapshot.
    public init(
        changeCount: Int,
        contents: [TerminalPasteboardItemSnapshot]
    ) {
        self.changeCount = changeCount
        self.contents = contents
    }
}
