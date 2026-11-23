import Foundation

/// What the Feed never shows (manaflow-ai/cmux#51332): the Chief's own machinery. Its memory
/// compactor runs `slot-<k>` sessions that finish a turn every few seconds, each prompted with the
/// raw `<chat>` view ("<chat> 0+2048|user: …") and answering "Compacted 10648–10651: …". The live
/// feed skips those sessions by their tags and names (`AcpmuxSession.isChiefCompactor`); these
/// rules catch what is left without them: a card saved by an older build, or a session whose
/// summary lost its tags.
public enum FeedInternal {
    /// The person's words in a prompt: a Chief view prompt (`<chat>…</chat>` then the task) is cut
    /// to the task after the view, "Your task:" dropped. Nil when nothing is left (a compactor's
    /// prompt is the view alone), so the card shows no quote.
    public static func shownPrompt(_ prompt: String) -> String? {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("<chat>") else { return trimmed.isEmpty ? nil : trimmed }
        guard let close = trimmed.range(of: "</chat>") else { return nil }
        var task = trimmed[close.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        for lead in ["Your task:", "Task:"] where task.hasPrefix(lead) {
            task = task.dropFirst(lead.count).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return task.isEmpty ? nil : task
    }

    /// A card a compactor slot made: its place is `slot-<k>` (the slot's folder), or its prompt is
    /// a bare `<chat>` view, or its reply is the compactor's "Compacted N–M" receipt.
    public static func isCompactorCard(_ item: FeedItem) -> Bool {
        if isSlotFolder(item.workspaceTitle), item.workspaceID.isEmpty { return true }
        if let quote = item.quote?.text, quote.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<chat>"),
           shownPrompt(quote) == nil { return true }
        return item.markdown.range(of: #"^Compacted [0-9]+([–-][0-9]+)?:"#, options: .regularExpression) != nil
    }

    /// `slot-0`, `slot-12`: a compactor slot's working folder.
    static func isSlotFolder(_ name: String) -> Bool {
        guard name.hasPrefix("slot-") else { return false }
        let number = name.dropFirst(5)
        return !number.isEmpty && number.allSatisfy(\.isNumber)
    }
}
