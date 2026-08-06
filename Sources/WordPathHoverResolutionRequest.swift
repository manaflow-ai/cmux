struct WordPathHoverResolutionRequest: Sendable {
    let identity: WordPathHoverResolutionIdentity
    let snapshot: WordPathResolutionSnapshot
    let renderedFrameGeneration: UInt64

    var key: WordPathHoverCacheKey {
        identity.key
    }

    func updatingRenderedFrameGeneration(_ generation: UInt64) -> Self {
        Self(
            identity: identity,
            snapshot: snapshot,
            renderedFrameGeneration: generation
        )
    }
}
