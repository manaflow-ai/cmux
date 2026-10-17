struct ArtifactParityAuditSnapshot {
    let detectedChannelsByPath: [String: Set<String>]
    let galleryPaths: Set<String>
    let violations: Set<String>
    let excludedGalleryPaths: Set<String>
    let nonAbsoluteGalleryPaths: Set<String>
}
