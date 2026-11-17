/// Whether a glass surface clips its content to its rounded shape.
// lint:allow namespace-type -- vendored CmuxConversation snapshot
public enum ConversationGlassClipping {
    /// `liquidGlass`: iOS 26's glass, which draws its own rounded shape.
    /// `contentReachesCorners`: content (a full-width attachment shelf, a
    /// link card) that would show past the rounded corners unclipped.
    /// Clipping a rounded view renders its whole subtree (the glass's
    /// backdrop and SDF layers included) in an offscreen pass every frame
    /// the content behind it moves, so glass clips only when it must.
    public static func clipsToBounds(liquidGlass: Bool, contentReachesCorners: Bool) -> Bool {
        !liquidGlass || contentReachesCorners
    }
}
