import Foundation

/// The raw tmux pane title and host values used to recognize its default title.
public struct RemoteTmuxPaneTitleMetadata: Equatable, Sendable {
    /// The in-format delimiter; some tmux control clients encode it as `\037`.
    public static let fieldSeparator: Character = "\u{1f}"
    /// The stable suffix marker separating a pane-rect label from its metadata.
    public static let paneRectMetadataMarker = "cmux_title_metadata_v1"

    /// The raw title emitted by tmux for the pane.
    public let title: String
    /// The full host name emitted by tmux for the pane.
    public let host: String
    /// The short host name emitted by tmux for the pane.
    public let hostShort: String

    /// Parses the title, full host, and short host emitted by a tmux format.
    ///
    /// - Parameter wireValue: The three fields separated by ``fieldSeparator``.
    public init?(wireValue: String) {
        let fields = wireValue.split(
            separator: Self.fieldSeparator,
            maxSplits: 2,
            omittingEmptySubsequences: false
        )
        guard fields.count == 3 else { return nil }
        self.init(
            title: String(fields[0]),
            host: String(fields[1]),
            hostShort: String(fields[2])
        )
    }

    /// Creates metadata from already-separated tmux format values.
    ///
    /// - Parameters:
    ///   - title: The raw pane title.
    ///   - host: The full host name used by tmux's default title.
    ///   - hostShort: The short host name used by tmux's default title.
    public init(title: String, host: String, hostShort: String) {
        self.title = title
        self.host = host
        self.hostShort = hostShort
    }

    /// Splits a pane-rect label into its visible header and decoded title metadata.
    ///
    /// tmux quotes format fields with backslashes. Depending on tmux version,
    /// control-mode command replies carry separators raw or as `\037`.
    /// - Parameter value: The label field emitted by the `list-panes` format.
    /// - Returns: The visible header and title metadata, or `nil` if no valid
    ///   metadata suffix is present.
    nonisolated public static func paneRectLabel(
        from value: String
    ) -> (header: String, metadata: RemoteTmuxPaneTitleMetadata)? {
        let bytes = Array(value.utf8)
        let marker = Array(Self.paneRectMetadataMarker.utf8)
        let markerStarts = bytes.indices.filter { start in
            start + marker.count <= bytes.count
                && bytes[start..<(start + marker.count)].elementsEqual(marker)
        }
        guard !markerStarts.isEmpty else { return nil }
        let octalSeparator: [UInt8] = [0x5c, 0x30, 0x33, 0x37]
        func separatorWidth(after markerStart: Int) -> Int? {
            let end = markerStart + marker.count
            if end < bytes.count, bytes[end] == 0x1f { return 1 }
            if end + octalSeparator.count <= bytes.count,
               bytes[end..<(end + octalSeparator.count)].elementsEqual(octalSeparator) {
                return octalSeparator.count
            }
            return nil
        }
        // The trailing marker identifies the wire encoding. Within that
        // encoding, start at the first candidate and reject malformed fields;
        // retrying at a marker inside a title could silently truncate it.
        guard let wireWidth = markerStarts.reversed().compactMap({ separatorWidth(after: $0) }).first,
              let firstMarker = markerStarts.first(where: { separatorWidth(after: $0) == wireWidth }) else {
            return nil
        }

        /// Decodes one byte range without applying tmux quoting rules.
        func field(_ start: Int, _ end: Int) -> String {
            String(decoding: bytes[start..<end], as: UTF8.self)
        }
        /// Removes tmux's one-byte backslash quoting from a metadata field.
        func unquote(_ encoded: String) -> String {
            let encodedBytes = Array(encoded.utf8)
            var decoded: [UInt8] = []
            decoded.reserveCapacity(encodedBytes.count)
            var offset = 0
            while offset < encodedBytes.count {
                if encodedBytes[offset] == 0x5c, offset + 1 < encodedBytes.count {
                    decoded.append(encodedBytes[offset + 1])
                    offset += 2
                } else {
                    decoded.append(encodedBytes[offset])
                    offset += 1
                }
            }
            return String(decoding: decoded, as: UTF8.self)
        }

        for markerStart in [firstMarker] {
            let markerEnd = markerStart + marker.count
            let separatorWidth = wireWidth
            let metadataStart = markerEnd + separatorWidth
            var separators: [Int] = []
            var mixedSeparators = false
            var offset = metadataStart
            while offset < bytes.count {
                if bytes[offset] == 0x1f {
                    if separatorWidth == 1 { separators.append(offset) }
                    else { mixedSeparators = true }
                    offset += 1
                } else if offset + octalSeparator.count <= bytes.count,
                          bytes[offset..<(offset + octalSeparator.count)].elementsEqual(octalSeparator) {
                    if separatorWidth == octalSeparator.count { separators.append(offset) }
                    else { mixedSeparators = true }
                    offset += octalSeparator.count
                } else if bytes[offset] == 0x5c, offset + 1 < bytes.count {
                    // q: escapes literal backslashes; do not treat a quoted
                    // literal `\\037` inside a field as a wire delimiter.
                    offset += 2
                } else {
                    offset += 1
                }
            }
            // Reject extra separators instead of assigning malformed fields.
            guard !mixedSeparators, separators.count == 2 else { continue }
            let first = separators[0]
            let second = separators[1]
            let metadata = Self(
                title: unquote(field(metadataStart, first)),
                host: unquote(field(first + separatorWidth, second)),
                hostShort: unquote(field(second + separatorWidth, bytes.count))
            )
            return (header: field(0, markerStart), metadata: metadata)
        }
        return nil
    }

    /// Applies a live raw-title value to prior snapshot metadata.
    ///
    /// A subscription normally contains only `#{pane_title}`. Before the first
    /// snapshot, retain the raw title with empty defaults; the snapshot later
    /// supplies host metadata without replacing this newer title.
    public static func applyingLiveWireValue(
        _ wireValue: String,
        to previous: RemoteTmuxPaneTitleMetadata?
    ) -> RemoteTmuxPaneTitleMetadata? {
        if let previous {
            return RemoteTmuxPaneTitleMetadata(
                title: wireValue,
                host: previous.host,
                hostShort: previous.hostShort
            )
        }
        return RemoteTmuxPaneTitleMetadata(title: wireValue, host: "", hostShort: "")
    }

    /// Retains a newer live title while incorporating default host fields from
    /// a delayed snapshot, so a default hostname does not become a custom title.
    public func applyingSnapshotDefaults(_ snapshot: RemoteTmuxPaneTitleMetadata) -> Self {
        Self(title: title, host: snapshot.host, hostShort: snapshot.hostShort)
    }

    /// A snapshot sent before a live event must not overwrite it when its
    /// reply arrives later on the control stream.
    public static func snapshotMayReplace(
        liveRevision: UInt64?,
        snapshotRevision: UInt64
    ) -> Bool {
        (liveRevision ?? 0) <= snapshotRevision
    }

    /// Returns a non-default title, or `nil` when tmux supplied its host title.
    public var intentionalTitle: String? {
        let title = Self.normalized(title)
        guard !title.isEmpty else { return nil }

        let defaultHosts = [host, hostShort]
            .map(Self.normalized)
            .filter { !$0.isEmpty }
        guard !defaultHosts.isEmpty else { return nil }
        guard !defaultHosts.contains(where: {
            $0.caseInsensitiveCompare(title) == .orderedSame
        }) else {
            return nil
        }
        return title
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
