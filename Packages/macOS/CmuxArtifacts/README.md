# CmuxArtifacts

`CmuxArtifacts` owns cmux's local, project-scoped artifact filesystem.

The package keeps ordinary user-organizable files under
`<project>/.cmux/artifacts/`. `LocalArtifactRepository` treats each live scan as
authoritative, while `ArtifactCaptureService` applies conservative automatic
capture limits before importing agent-created files. Content-addressed capture
history is stored under `.cmux/artifacts/.cmux/provenance/`, allowing files to
be moved or renamed without losing deduplication.

App, CLI, and sidebar callers share the `ArtifactStoring` protocol. UI code must
project `ArtifactSnapshot` values into immutable rows instead of retaining the
repository below a list boundary.

Projects can override the conservative defaults with a partial
`.cmux/artifacts.json` file. Supported keys are `automaticCaptureEnabled`,
`captureCreatedAndAttached`, `captureReferencedEphemeral`, `maximumFileBytes`,
`maximumTextFileBytes`, `maximumFilesPerCapture`, `deduplicationScanNodeLimit`,
`deduplicationHashByteLimit`, `contentSearchMaximumBytes`,
`contentSearchTotalMaximumBytes`, `maximumSearchResults`, `allowedExtensions`, and
`ephemeralPathPrefixes`; omitted keys inherit the defaults in
`ArtifactCaptureConfiguration`.
