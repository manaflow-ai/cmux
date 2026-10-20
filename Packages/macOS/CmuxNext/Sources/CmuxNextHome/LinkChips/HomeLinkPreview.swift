public import AppKit
public import CmuxNextDesign
public import MessagesLabHome

/// What a link chip's hover card shows (plans/cmux-next/home-link-chips-DESIGN.md): the target's
/// live title, where it is, its state, a few lines of its content and an optional picture.
public struct HomeLinkPreview: Equatable {
    /// What the chip points at; the card's icon.
    public var kind: HomeLinkChipKind
    /// The target's live title (a workspace's name, a tab's title, a file's name).
    public var title: String
    /// Where it is: a workspace, a folder, a page's URL, a repository.
    public var place: String?
    /// A short state word ("Open", "Closed") and its tone.
    public var status: String?
    /// The tone of ``status``.
    public var statusTone: HoverCardTone
    /// Content lines: a terminal's last lines, a document's first lines, a workspace's tabs.
    public var lines: [String]
    /// Whether ``lines`` are code or terminal text (monospaced).
    public var monospaced: Bool
    /// A picture of the target (a browser page's thumbnail).
    public var thumbnail: CGImage?

    /// - Parameters:
    ///   - kind: what the chip points at.
    ///   - title: the target's live title.
    ///   - place: where it is, if known.
    ///   - status: a short state word, if any.
    ///   - statusTone: the state's tone (secondary by default).
    ///   - lines: content lines (none by default).
    ///   - monospaced: whether the lines are code or terminal text.
    ///   - thumbnail: a picture of the target.
    public init(kind: HomeLinkChipKind, title: String, place: String? = nil, status: String? = nil,
                statusTone: HoverCardTone = .secondary, lines: [String] = [], monospaced: Bool = false, thumbnail: CGImage? = nil) {
        self.kind = kind
        self.title = title
        self.place = place
        self.status = status
        self.statusTone = statusTone
        self.lines = lines
        self.monospaced = monospaced
        self.thumbnail = thumbnail
    }
}

/// The app's side of link chip previews: what a chip's target is now. The App implements it over
/// its models; tests pass a fake.
@MainActor
public protocol HomeLinkPreviewing: AnyObject {
    /// The preview from what the app knows at once (titles, state), shown when the card opens.
    func preview(for url: URL, kind: HomeLinkChipKind) -> HomeLinkPreview
    /// `preview` with the slower facts added (a terminal's lines, a file's first lines, a
    /// thumbnail); the card updates when it returns. Returns `preview` when there is nothing more.
    func details(for url: URL, preview: HomeLinkPreview) async -> HomeLinkPreview
}
