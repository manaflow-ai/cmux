/// Where a web link opened from an agent chat lands (`links.openTarget` in cmux.json): a link in a
/// reply, a pull request chip, the hover card's Open. Command-click opens it in the same place, in
/// the background. The chat itself never gets covered (Leo 2026-10-21).
///
/// ```jsonc
/// "links": { "openTarget": "rightmost" }   // "newSplit", "sameTab"
/// ```
public nonisolated enum ChatLinkTarget: String, Hashable, Sendable, CaseIterable {
    /// A tab in the rightmost split of the chat's screen; when the chat is that split, a new split
    /// on its right. A pane left of the chat never gets it. The default.
    case rightmost
    /// Always a new split on the chat's right.
    case newSplit
    /// A tab in the chat's own pane, as any page opens a link (cmux-next before 2026-10-21; with
    /// `layout.mainPane` on, the column beside the chat).
    case sameTab

    /// The cmux.json key.
    public static let configPath = ["links", "openTarget"]
    /// ``rightmost`` when the key is unset or invalid.
    public static let fallback: ChatLinkTarget = .rightmost
}
