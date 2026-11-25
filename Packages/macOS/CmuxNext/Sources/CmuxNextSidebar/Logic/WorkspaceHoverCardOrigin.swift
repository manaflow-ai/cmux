import CmuxNextDesign
import CmuxNextIcons
import Foundation

/// Who made a workspace and why, as the hover card says it (Leo 2026-11-19: "what was everybody
/// doing with the tiny weather space and the example domain space in cmux next on cosmic-gray?" /
/// "acpmux should expose these a lot better"). The daemon records the creator
/// (`extra.created_by`: the acpmux session's name and id, its host, a one-line purpose); the card
/// only words it, quietly, in the metadata ink. A workspace the person made has no origin and gets
/// no line. Pure.
enum WorkspaceHoverCardOrigin {
    /// How the card shows the origin. The gallery shows all three (`WorkspaceHoverCardGallery`);
    /// `shipped` is the one the app draws.
    enum Style: String, CaseIterable, Sendable {
        /// "desktop-helper on studio-mac" by the agent's icon, then the purpose on its own line
        /// (the shipped one).
        case line
        /// One line, "Made by desktop-helper · studio-mac: <purpose>", wrapped to two lines.
        case byline
        /// A dimmer caption at the card's end, under the preview: the purpose, then
        /// "— desktop-helper@studio-mac".
        case footer
    }

    /// The style the card draws: one metadata fact per row, each by its icon, like every other
    /// line of the card (Claude desktop's session card: a title, muted metadata, the message). The
    /// creator reads at a glance and the purpose keeps its own two lines; the byline packs both
    /// behind one icon and cuts the purpose first, and the footer would put metadata under the
    /// preview, which stays the card's last line.
    static let shipped = Style.line

    /// The fact kind of the creator's line and of the purpose's line (the byline and footer are
    /// one `creatorKind` line).
    static let creatorKind = "createdBy"
    static let purposeKind = "purpose"

    /// Whether `style` goes at the card's end, after the preview, not among the metadata.
    static func isFooter(_ style: Style) -> Bool { style == .footer }

    /// The creator's name: the session's name, else the start of its id, else "Script" for a
    /// script with no session; nil for an agent that names no session.
    static func creator(_ origin: SidebarWorkspaceOrigin) -> String? {
        origin.creator ?? (origin.kind == .script ? Strings.originScript : nil)
    }

    /// The card's lines for `detail`'s origin in `style`; none for a workspace the person made. A
    /// purpose that only repeats the card's `title` is left out.
    static func facts(_ detail: SidebarWorkspaceDetail, style: Style = shipped, title: String? = nil) -> [WorkspaceHoverCardContent.Fact] {
        typealias Fact = WorkspaceHoverCardContent.Fact
        guard let origin = detail.origin else { return [] }
        let icon: IconName = origin.kind == .agent ? .agentBot : .automation
        let who = creator(origin)
        let shownTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let purpose: String? = origin.purpose.flatMap { (purpose: String) -> String? in
            guard let shownTitle, purpose.caseInsensitiveCompare(shownTitle) == .orderedSame else { return purpose }
            return nil
        }
        switch style {
        case .line:
            let place: String? = switch (who, origin.host) {
            case let (who?, host?): Strings.originOnHost(who, host)
            case let (who?, nil): who
            case let (nil, host?): host
            case (nil, nil): nil
            }
            let head = place.map { Fact(icon: icon, text: $0, kind: creatorKind) }
            let reason = purpose.map { Fact(icon: .textDescription, text: $0, lines: 2, kind: purposeKind) }
            return [head, reason].compactMap { $0 }
        case .byline:
            let maker = [who, origin.host].compactMap { $0 }.joined(separator: WorkspaceRowContent.separator)
            let text = switch (maker.isEmpty, purpose) {
            case (false, let purpose?): Strings.originMadeBy(maker) + ": " + purpose
            case (false, nil): Strings.originMadeBy(maker)
            case (true, let purpose?): purpose
            case (true, nil): ""
            }
            return text.isEmpty ? [] : [Fact(icon: icon, text: text, lines: 2, kind: creatorKind)]
        case .footer:
            let signature = [who, origin.host].compactMap { $0 }.joined(separator: "@")
            let parts = [purpose, signature.isEmpty ? nil : "— " + signature].compactMap { $0 }
            guard !parts.isEmpty else { return [] }
            return [Fact(icon: icon, text: parts.joined(separator: " "), lines: 2, kind: creatorKind, ink: .tertiary, iconTone: .tertiary)]
        }
    }
}
