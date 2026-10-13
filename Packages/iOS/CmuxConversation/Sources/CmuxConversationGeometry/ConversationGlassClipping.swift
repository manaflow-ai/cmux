/// Whether a glass surface clips its content to its rounded shape.
public enum ConversationGlassClipping {
    /// `liquidGlass`: iOS 26's glass, which draws its own rounded shape.
    /// `contentReachesCorners`: content (a full-width attachment shelf, a
    /// link card) that would show past the rounded corners unclipped.
    public static func clipsToBounds(liquidGlass: Bool, contentReachesCorners: Bool) -> Bool {
        true
    }
}
