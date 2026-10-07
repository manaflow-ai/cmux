import Foundation

/// The raw tmux pane title and host values used to recognize its default title.
public struct RemoteTmuxPaneTitleMetadata: Equatable, Sendable {
    /// A control character that tmux leaves untouched in format expansions.
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
    /// tmux quotes format fields with backslash-octal escapes. The marker is
    /// explicit because a title may itself contain the serialized separator.
    /// - Parameter value: The label field emitted by the `list-panes` format.
    /// - Returns: The visible header and title metadata, or `nil` if no valid
    ///   metadata suffix is present.
    nonisolated public static func paneRectLabel(
        from value: String
    ) -> (header: String, metadata: RemoteTmuxPaneTitleMetadata)? {
        let bytes = Array(value.utf8)
        let marker = Array((Self.paneRectMetadataMarker + "\\037").utf8)
        let markerStarts = bytes.indices.filter { start in
            start + marker.count <= bytes.count
                && bytes[start..<(start + marker.count)].elementsEqual(marker)
        }
        guard !markerStarts.isEmpty else { return nil }

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

        for markerStart in markerStarts.reversed() {
            let metadataStart = markerStart + marker.count
            var separators: [Int] = []
            var index = metadataStart
            while index + 3 < bytes.count, separators.count < 2 {
                guard bytes[index] == 0x5c,
                      bytes[index + 1] == 0x30,
                      bytes[index + 2] == 0x33,
                      bytes[index + 3] == 0x37 else {
                    index += 1
                    continue
                }
                var precedingBackslashes = 0
                var preceding = index
                while preceding > metadataStart, bytes[preceding - 1] == 0x5c {
                    precedingBackslashes += 1
                    preceding -= 1
                }
                if precedingBackslashes.isMultiple(of: 2) {
                    separators.append(index)
                    index += 4
                } else {
                    index += 1
                }
            }
            guard separators.count == 2 else { continue }
            let first = separators[0]
            let second = separators[1]
            let wireValue = [
                unquote(field(metadataStart, first)),
                unquote(field(first + 4, second)),
                unquote(field(second + 4, bytes.count)),
            ].joined(separator: String(Self.fieldSeparator))
            guard let metadata = Self(wireValue: wireValue) else { continue }
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
