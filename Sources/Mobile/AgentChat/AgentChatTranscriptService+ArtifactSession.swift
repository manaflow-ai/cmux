extension AgentChatTranscriptService {
    /// Resolves the live or most recently active session bound to a terminal surface.
    ///
    /// - Parameter surfaceID: Terminal surface UUID string.
    /// - Returns: The session record used for a terminal's session-wide artifact gallery.
    func currentOrMostRecentSessionRecord(surfaceID: String) -> AgentChatSessionRecord? {
        registry.currentOrMostRecentSession(surfaceID: surfaceID)
    }
}
