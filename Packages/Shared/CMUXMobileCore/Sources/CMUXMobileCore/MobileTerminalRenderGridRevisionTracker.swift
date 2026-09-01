import Foundation

/// Separates rendered-content revisions from exact frame-emission identities.
///
/// ``renderRevision`` is a stable polling token: it advances when the visible
/// grid or its dimensions change, and it does not advance when the same frame
/// is replayed. ``emissionRevision`` advances for every frame the producer
/// emits, including an unchanged replay, so delta consumers can still prove
/// that their base is the exact frame the producer diffed against.
public struct MobileTerminalRenderGridRevisionTracker: Sendable {
    /// The producer identity attached to one emitted frame.
    public struct Identity: Equatable, Sendable {
        /// Producer lifetime. A new terminal runtime starts a new epoch.
        public let renderEpoch: String
        /// Stable rendered-content revision for polling.
        public let renderRevision: UInt64
        /// Exact emitted-frame identity for delta continuity.
        public let emissionRevision: UInt64

        public init(
            renderEpoch: String,
            renderRevision: UInt64,
            emissionRevision: UInt64
        ) {
            self.renderEpoch = renderEpoch
            self.renderRevision = renderRevision
            self.emissionRevision = emissionRevision
        }
    }

    private struct Content: Equatable, Sendable {
        let columns: Int
        let rows: Int
        let activeScreen: MobileTerminalRenderGridFrame.Screen
        let anchor: MobileTerminalRenderGridFrame.Anchor
        let rowSignatures: [String]
        let scrollbackRows: Int
        let scrollbackSignatures: [String]
        let cursor: MobileTerminalRenderGridFrame.Cursor?
        let terminalForeground: String?
        let terminalBackground: String?
        let terminalCursorColor: String?
        let terminalTheme: TerminalTheme?
        let terminalConfigTheme: TerminalTheme?
    }

    private let renderEpoch: String
    private var renderRevision: UInt64 = 0
    private var emissionRevision: UInt64 = 0
    private var lastContent: Content?

    /// Creates a tracker for one terminal-runtime lifetime.
    ///
    /// - Parameter renderEpoch: Stable producer epoch. The default is a new
    ///   UUID, while a surface owner may inject an existing epoch when it
    ///   creates an anchor-specific tracker.
    public init(renderEpoch: String = UUID().uuidString) {
        self.renderEpoch = renderEpoch
    }

    /// The current identity before another frame is emitted.
    public var currentIdentity: Identity {
        Identity(
            renderEpoch: renderEpoch,
            renderRevision: renderRevision,
            emissionRevision: emissionRevision
        )
    }

    /// Records one complete rendered frame and returns its identity.
    ///
    /// The frame must be a full snapshot. Transport metadata such as
    /// ``MobileTerminalRenderGridFrame/stateSeq``, theme metadata revisions,
    /// and non-visual mode flags are deliberately excluded from the content
    /// comparison, so output that does not alter visible pixels remains on the
    /// same polling revision.
    /// Every successful call still receives a distinct emission revision.
    ///
    /// - Parameter fullFrame: Complete frame exported by the producer before
    ///   transport filtering or delta encoding.
    /// - Returns: The content and emission revisions for this frame.
    public mutating func record(
        fullFrame: MobileTerminalRenderGridFrame
    ) -> Identity {
        let content = Self.content(of: fullFrame)
        if lastContent != content {
            renderRevision &+= 1
            if renderRevision == 0 {
                renderRevision = 1
            }
            lastContent = content
        }
        emissionRevision &+= 1
        if emissionRevision == 0 {
            emissionRevision = 1
        }
        return currentIdentity
    }

    private static func content(
        of frame: MobileTerminalRenderGridFrame
    ) -> Content {
        var stylesByID: [Int: MobileTerminalRenderGridFrame.Style] = [:]
        for style in frame.styles {
            stylesByID[style.id] = style
        }
        let scrollbackSignatures = frame.scrollbackSpans
            .sorted {
                if $0.row != $1.row { return $0.row < $1.row }
                return $0.column < $1.column
            }
            .map { span in
                let style = stylesByID[span.styleID] ?? .default
                return "\(span.row):\(span.column):\(span.gridCellWidth):" +
                    "\(Self.styleSignature(style)):\(span.text)"
            }
        return Content(
            columns: frame.columns,
            rows: frame.rows,
            activeScreen: frame.activeScreen,
            anchor: frame.anchor,
            rowSignatures: frame.rowSignatures(),
            scrollbackRows: frame.scrollbackRows,
            scrollbackSignatures: scrollbackSignatures,
            cursor: frame.cursor,
            terminalForeground: frame.terminalForeground,
            terminalBackground: frame.terminalBackground,
            terminalCursorColor: frame.terminalCursorColor,
            terminalTheme: frame.terminalTheme,
            terminalConfigTheme: frame.terminalConfigTheme
        )
    }

    private static func styleSignature(
        _ style: MobileTerminalRenderGridFrame.Style
    ) -> String {
        let flags = [
            style.bold,
            style.faint,
            style.italic,
            style.underline,
            style.blink,
            style.inverse,
            style.invisible,
            style.strikethrough,
            style.overline,
        ]
            .map { $0 ? "1" : "0" }
            .joined()
        let foregroundSource = style.foregroundSource?.rawValue ?? "legacy"
        let backgroundSource = style.backgroundSource?.rawValue ?? "legacy"
        return "\(style.foreground ?? "-"):\(foregroundSource):\(style.foregroundPaletteIndex ?? -1)/" +
            "\(style.background ?? "-"):\(backgroundSource):\(style.backgroundPaletteIndex ?? -1)/\(flags)"
    }
}
